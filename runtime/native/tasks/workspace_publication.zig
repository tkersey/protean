const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const workspace = @import("../workspace_state.zig");
const instrument = @import("../workspace_instrument.zig");
const wp = @import("../workspace_projection.zig");
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const Work = task_types.Work;
const name = task_types.name;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const prepareCommit = prepareWorkspaceCommitPublication;
        const freezeWorkspaceWork = Access.freezeWorkspaceWork;
        const hasFrozenCustody = Lifecycle.hasFrozenCustody;
        const hasLocalCustody = Lifecycle.hasLocalCustody;
        const operationKey = Records.operationKey;
        const persistScheduled = Records.persistScheduled;
        const publicationReadsController = Replay.publicationReadsController;
        const record = Records.record;
        const replay = Records.replay;
        const requireCustody = Lifecycle.requireCustody;
        const residualPublication = Residuals.residualPublication;
        const store = Lifecycle.store;
        const subjectPublicationEvent = Records.subjectPublicationEvent;
        const subjectRemove = Scheduling.subjectRemove;
        const unclaim = Scheduling.unclaim;
        const validateControllerInteraction = ControllerProtocol.validateControllerInteraction;
        const validateControllerResidual = Residuals.validateControllerResidual;
        const validateControllerSuccession = SuccessionValidation.validateControllerSuccession;
        const workPublication = Access.workPublication;
        const workspaceOuterCursor = Observers.workspaceOuterCursor;
        const workspaceParentStopped = Access.workspaceParentStopped;
        const workspaceRunnable = Execution.workspaceRunnable;
        const workspaceSettled = Tasks.workspaceSettled;
        const workspaceSnapshotAccess = Inspection.workspaceSnapshotAccess;
        const workspaceStartAdmitted = Start.workspaceStartAdmitted;
        const workspaceStoreProgram = Programs.workspaceStoreProgram;
        const workspaceValueReference = Contexts.workspaceValueReference;
        const ControllerProtocol = @import("controller_protocol.zig").Operations(Types, Self);
        const Residuals = @import("controller_residuals.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);
        const SuccessionValidation = @import("succession_validation.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Contexts = @import("workspace_contexts.zig").Operations(Types, Self);
        const Execution = @import("workspace_execution.zig").Operations(Types, Self);
        const Inspection = @import("workspace_inspection.zig").Operations(Types, Self);
        const Observers = @import("workspace_observers.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Replay = @import("workspace_replay.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        const Start = @import("workspace_start.zig").Operations(Types, Self);
        pub fn workspaceCommit(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            operation_id: ?[]const u8,
            request: state.Digest,
            identity: state.Digest,
            kind: @FieldType(contracts.workspace.Ref, "kind"),
            observation: state.Reference,
            command: ?workspace.PublicationCommand,
        ) !Admission {
            return workspaceCommitRelated(
                self,
                a,
                initial,
                operation_id,
                request,
                identity,
                kind,
                observation,
                null,
                command,
            );
        }
        pub fn workspaceCommitRelated(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            operation_id: ?[]const u8,
            request: state.Digest,
            identity: state.Digest,
            kind: @FieldType(contracts.workspace.Ref, "kind"),
            observation: state.Reference,
            related: ?state.Digest,
            command: ?workspace.PublicationCommand,
        ) !Admission {
            var parent = initial;
            parent.revision = try std.math.add(u64, parent.revision, 1);
            const event_data = try std.fmt.allocPrint(a, "{{\"workspace_id\":\"{s}\"}}", .{
                std.fmt.bytesToHex(identity, .lower),
            });
            defer a.free(event_data);
            var commit: WorkspaceCommitPublication = .{ .frozen = observation };
            defer if (commit.decoded_work) |*work| work.deinit();
            var receipt_id: state.Digest = undefined;
            try self.io.randomSecure(&receipt_id);
            try prepareCommit(self, a, parent.id, identity, kind, observation, related, &commit);
            try publishWorkspaceCommitEvent(
                self,
                a,
                initial,
                &parent,
                operation_id,
                event_data,
                command,
                &commit,
            );
            const saved: state.Receipt = .{
                .id = receipt_id,
                .client_operation_id = try name(operation_id orelse "workspace.progress"),
                .method = .workspace,
                .request_digest = request,
                .task = parent.id,
                .revision = parent.revision,
                .disposition = .accepted,
                .workspace = identity,
                .workspace_kind = kind,
                .workspace_observation = commit.frozen,
            };
            if (operation_id) |op| {
                const bytes = try contracts.encodeOwned(state.Receipt, a, saved);
                defer a.free(bytes);
                const key = try operationKey(self, a, op);
                try store(self).putReceipt(&key, request, bytes);
            }
            try scheduleWorkspaceCommit(
                self,
                a,
                parent,
                initial.revision,
                identity,
                kind,
                commit.decoded_work,
            );
            return .{ .receipt = saved, .replayed = false };
        }
        pub fn workspaceDelegate(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            authorized: workspace.Authorized,
        ) !Admission {
            const selection = authorized.command.work.delegate;
            const Request = workspace.DelegationRequest;
            const request = try operation(Request, a, .{ .task = task_id, .command = selection });
            if (try replay(self, a, operation_id, request)) |prior| return prior;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            if (workspaceParentStopped(self, parent.value)) return error.InvalidState;
            const parent_occurrence = parent.value.current_occurrence orelse
                return error.InvalidDelegation;
            const operation_name = std.fmt.bytesToHex(parent_occurrence, .lower);
            if (!same(operation_id, &operation_name)) return error.InvalidDelegation;
            var original = try record(
                self,
                occurrence.Occurrence,
                a,
                "occurrence",
                parent_occurrence,
                task_id,
            );
            defer original.deinit();
            if (original.value.work != null or original.value.state != .ready)
                return error.InvalidDelegation;
            const target_id = try wp.identity(selection.expected.work, .work);
            try requireCustody(self, a, task_id, target_id);
            var target = try self.workspaceWork(a, task_id, target_id);
            defer target.deinit();
            if (target.value.execution_revision != selection.expected.execution_revision or
                target.value.control_revision != selection.expected.control_revision)
                return error.StaleRevision;
            if (target.value.terminal() or target.value.cancellation != null)
                return error.InvalidState;
            const port_ref = target.value.current_port orelse return error.NoExposedPort;
            var port = try contracts.decodeOwned(
                workspace.Port,
                a,
                try store(self).object(a, port_ref, null),
            );
            defer port.deinit();
            try validateDelegatePort(self, a, task_id, selection, port.value);
            return publishWorkspaceDelegation(
                self,
                a,
                operation_id,
                task_id,
                authorized,
                parent.value,
                original.value,
                target.value,
                port.value,
                port_ref,
                request,
            );
        }
        pub fn writeWorkspaceWork(self: *Self, work: *workspace.Work, mode: enum {
            create,
            replace,
        }) !void {
            work.outer_cursor = try workspaceOuterCursor(work.*);
            switch (mode) {
                .create => try store(self).createRecord(
                    workspace.Work,
                    "workspace_work",
                    work.id,
                    work.task,
                    work.*,
                ),
                .replace => try store(self).putRecord(
                    workspace.Work,
                    "workspace_work",
                    work.id,
                    work.task,
                    work.*,
                ),
            }
        }
        fn prepareWorkspaceCommitPublication(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            identity: state.Digest,
            kind: @FieldType(contracts.workspace.Ref, "kind"),
            observation: state.Reference,
            related: ?state.Digest,
            publication: *WorkspaceCommitPublication,
        ) !void {
            if (kind == .work) {
                const bytes = try store(self).object(a, observation, null);
                defer a.free(bytes);
                publication.decoded_work = try contracts.decodeOwned(workspace.Work, a, bytes);
                const work = publication.decoded_work.?;
                var pending: ?contracts.Decoded(occurrence.Occurrence) = null;
                defer if (pending) |*value| value.deinit();
                if (work.value.current_occurrence) |id| pending =
                    try record(self, occurrence.Occurrence, a, "occurrence", id, task_id);
                const observed: workspace.WorkObservation = .{
                    .work = work.value,
                    .occurrence = if (pending) |value| value.value else null,
                };
                publication.publications[publication.publication_count] =
                    try workPublication(a, observed);
                publication.publication_count += 1;
                const snapshot = try contracts.encodeOwned(workspace.WorkObservation, a, observed);
                defer a.free(snapshot);
                publication.frozen = try store(self).putObject(snapshot);
            }
            if (kind == .residual) {
                var saved_residual = try record(
                    self,
                    state.ControllerResidual,
                    a,
                    "controller_residual",
                    identity,
                    task_id,
                );
                defer saved_residual.deinit();
                publication.residuals[0] =
                    try residualPublication(self, a, saved_residual.value);
                publication.residual_count = 1;
            }
            if (related) |id| {
                const observed =
                    try freezeWorkspaceWork(self, a, task_id, try wp.reference(a, .work, id), true);
                const snapshot = try contracts.encodeOwned(workspace.WorkObservation, a, observed);
                defer a.free(snapshot);
                _ = try store(self).putObject(snapshot);
                publication.publications[publication.publication_count] =
                    try workPublication(a, observed);
                publication.publication_count += 1;
            }
        }
        const WorkspaceCommitPublication = workspaceCommitPublicationType();
        fn workspaceCommitPublicationType() type {
            return struct {
                publications: [2]state.WorkPublication = undefined,
                publication_count: usize = 0,
                residuals: [1]state.ResidualPublication = undefined,
                residual_count: usize = 0,
                frozen: state.Reference,
                decoded_work: ?contracts.Decoded(workspace.Work) = null,
            };
        }
        fn scheduleWorkspaceCommit(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial_revision: u64,
            identity: state.Digest,
            kind: @FieldType(contracts.workspace.Ref, "kind"),
            decoded_work: ?contracts.Decoded(workspace.Work),
        ) !void {
            var scheduled: [1]workspace.Subject = undefined;
            var scheduled_count: usize = 0;
            var stopped: ?workspace.Subject = null;
            if (decoded_work) |work| {
                const subject: workspace.Subject = .{ .task = parent.id, .work = work.value.id };
                if (try workspaceRunnable(self, a, parent, work.value)) {
                    scheduled[scheduled_count] = subject;
                    scheduled_count += 1;
                } else stopped = subject;
            } else if (kind == .residual) {
                var residual = try record(
                    self,
                    state.ControllerResidual,
                    a,
                    "controller_residual",
                    identity,
                    parent.id,
                );
                defer residual.deinit();
                const subject: workspace.Subject = .{ .task = parent.id, .residual = identity };
                if (residual.value.schedule == .queued) {
                    scheduled[scheduled_count] = subject;
                    scheduled_count += 1;
                } else stopped = subject;
            }
            const disposed = if (try hasLocalCustody(self, a, parent.id, null) or
                try hasFrozenCustody(self, a, parent.id, null))
                parent.terminal() and try self.taskCleanupComplete(a, parent)
            else
                try workspaceSettled(self, a, parent.id, true, false, false);
            try persistScheduled(
                self,
                a,
                parent,
                initial_revision,
                "workspace.publish",
                .acquire,
                scheduled[0..scheduled_count],
            );
            if (stopped) |subject| subjectRemove(self, subject);
            if (disposed) unclaim(self, parent.id);
        }
        fn validateDelegatePort(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            selection: anytype,
            port: workspace.Port,
        ) !void {
            const selected_port = switch (selection.interpretation) {
                .model => |v| v.port,
                .snapshot => |v| v.port,
                .none => return error.InvalidDelegation,
            };
            const generation = switch (selection.interpretation) {
                .model => |v| v.generation,
                .snapshot => |v| v.generation,
                .none => unreachable,
            };
            if (!std.meta.eql(try wp.identity(selected_port, .port), port.id) or
                generation != port.generation or port.interface.class == .observation)
                return error.StaleOccurrence;
            var pending =
                try record(self, occurrence.Occurrence, a, "occurrence", port.occurrence, task_id);
            defer pending.deinit();
            if (pending.value.state != .ready) return error.UnsettledOccurrence;
        }
        fn publishWorkspaceDelegation(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            authorized: workspace.Authorized,
            parent: state.Task,
            original: occurrence.Occurrence,
            target: workspace.Work,
            port: workspace.Port,
            port_ref: state.Reference,
            request: state.Digest,
        ) !Admission {
            const selection = authorized.command.work.delegate;
            const parent_occurrence = parent.current_occurrence.?;
            const target_id = target.id;
            const kind: instrument.Kind =
                if (selection.interpretation == .model) .model else .snapshot;
            if (kind == .model and (authorized.model == null or !self.profile.authority.inference))
                return error.Denied;
            if (kind == .snapshot) try workspaceSnapshotAccess(
                parent,
                authorized.snapshot orelse return error.Denied,
            );
            var inputs: std.ArrayList(state.Reference) = .empty;
            defer inputs.deinit(a);
            if (selection.interpretation ==
                .model) for (selection.interpretation.model.inputs.items) |ref|
            {
                const value = try workspaceValueReference(self, a, task_id, ref);
                try inputs.append(a, value.artifact);
            };
            var built = try instrument.build(a, kind);
            defer built.deinit();
            try store(self).begin();
            defer store(self).rollback();
            const program = try publishDelegationProgram(self, a, task_id, parent, kind, built);
            var id: state.Digest = undefined;
            var instrument_id: state.Digest = undefined;
            try self.io.randomSecure(&id);
            try self.io.randomSecure(&instrument_id);
            const record_value: workspace.Delegation = .{
                .id = id,
                .task = task_id,
                .parent_occurrence = parent_occurrence,
                .parent_request = original.request_object,
                .work = target_id,
                .instrument = instrument_id,
                .program = port.program,
                .port = port_ref,
                .control_revision = try std.math.add(u64, target.control_revision, 1),
                .selection = selection.interpretation,
                .model = authorized.model,
                .snapshot = if (kind == .snapshot) authorized.snapshot else null,
                .inputs = .{ .items = inputs.items },
            };
            return startDelegatedInstrument(
                self,
                a,
                operation_id,
                task_id,
                program,
                record_value,
                request,
                selection,
            );
        }
        fn publishWorkspaceCommitEvent(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            parent: *state.Task,
            operation_id: ?[]const u8,
            event_data: []const u8,
            command: ?workspace.PublicationCommand,
            publication: *const WorkspaceCommitPublication,
        ) !void {
            const command_ref: ?state.Reference = if (command) |value| blk: {
                const bytes = try contracts.encodeOwned(workspace.PublicationCommand, a, value);
                defer a.free(bytes);
                break :blk try store(self).putObject(bytes);
            } else null;
            // Internal program publication is observed through the subsequent
            // work/delegation or captured build reply. Only work progress has
            // the retained publication facts needed for a journal projection.
            if (operation_id != null or publication.publication_count != 0 or
                publication.residual_count != 0)
                try subjectPublicationEvent(
                    self,
                    parent,
                    if (operation_id != null) .workspace else .workspace_progress,
                    event_data,
                    publication.publications[0..publication.publication_count],
                    publication.residuals[0..publication.residual_count],
                    command_ref,
                    if (command != null and
                        publicationReadsController(command.?)) .from(initial) else null,
                    null,
                );
        }
        fn publishDelegationProgram(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            parent: state.Task,
            kind: instrument.Kind,
            built: anytype,
        ) !state.Reference {
            const program = try workspaceStoreProgram(
                self,
                a,
                task_id,
                instrument.identity,
                if (kind == .model) .instrument_model else .instrument_snapshot,
                null,
                &.{},
                .{ .image = .{
                    .bytes = built.image,
                }, .interface = built.interface, .ports = .{ .items = &.{} } },
            );
            // This publication grants reusable immutable code, never execution.
            _ = try workspaceCommit(
                self,
                a,
                parent,
                null,
                @splat(0),
                program.digest,
                .program,
                program,
                null,
            );
            try self.checked_workspace_programs.put(
                self.allocator,
                program.digest,
                store(self).integrity_epoch,
            );
            return program;
        }
        fn startDelegatedInstrument(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            program: state.Reference,
            record_value: workspace.Delegation,
            request: state.Digest,
            selection: anytype,
        ) !Admission {
            const record_bytes = try contracts.encodeOwned(workspace.Delegation, a, record_value);
            defer a.free(record_bytes);
            const input = try contracts.encodeOwned(instrument.Input, a, .{ .delegation = .{
                .digest = storage.digest(record_bytes),
                .bytes = record_bytes.len,
            } });
            defer a.free(input);
            return workspaceStartAdmitted(
                self,
                a,
                operation_id,
                task_id,
                program.digest,
                input,
                .{ .stop = .terminal, .continuation = .owner_scheduled },
                null,
                .{
                    .record = record_value,
                    .request = request,
                    .policy = selection.policy,
                    .command = selection,
                },
                null,
                .{ .none = .{} },
                null,
                null,
            );
        }
        pub fn validateArchiveControllerRecord(
            self: *Self,
            parent: state.Task,
            row: state.ArchiveRecord,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            switch (row.kind) {
                .controller_succession => try validateControllerSuccession(
                    self,
                    self.allocator,
                    parent,
                    row.id,
                    records,
                    checked,
                ),
                .controller_residual => try validateControllerResidual(
                    self,
                    self.allocator,
                    parent,
                    row.id,
                    records,
                ),

                .controller_interaction => try validateControllerInteraction(
                    self,
                    self.allocator,
                    parent,
                    row.id,
                    records,
                ),

                else => unreachable,
            }
        }
    };
}
