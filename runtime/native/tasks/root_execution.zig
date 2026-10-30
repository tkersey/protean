const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const evaluator = @import("../driver.zig");
const json = @import("../json.zig");
const values = @import("../values.zig");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const OccurrenceSubject = task_types.OccurrenceSubject;
const Step = task_types.Step;
const name = task_types.name;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const ControllerProtocol = @import("controller_protocol.zig").Operations(Types, Self);
        const Residuals = @import("controller_residuals.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Messages = @import("messages.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Recovery = @import("work_recovery.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Contexts = @import("workspace_contexts.zig").Operations(Types, Self);
        const control_ops = @import("workspace_control.zig").Operations(Types, Self);
        const Observations = @import("workspace_observations.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const publication_ops = @import("workspace_publication.zig").Operations(Types, Self);
        const Decoded = contracts.Decoded;
        const blocked = Messages.blocked;
        const canonicalBounded = json.canonicalBounded;
        const controllerRequest = ControllerProtocol.controllerRequest;
        const decodeOwned = contracts.decodeOwned;
        const event = Records.event;
        const hasLocalCustody = Lifecycle.hasLocalCustody;
        const messageEvent = Records.messageEvent;
        const persist = Records.persist;
        const persistScheduled = Records.persistScheduled;
        const publicationEvent = Records.publicationEvent;
        const putRootOperation = Controller.putRootOperation;
        const record = Records.record;
        const resident = Lifecycle.resident;
        const residualProgressEvent = Residuals.residualProgressEvent;
        const retainedWorkspaceWork = Programs.retainedWorkspaceWork;
        const rootConsumed = Controller.rootConsumed;
        const rootIdentity = Controller.rootIdentity;
        const rootImage = Controller.rootImage;
        const rootProgramIdentity = Controller.rootProgramIdentity;
        const rootRouteImage = Controller.rootRouteImage;
        const runnableRemove = Scheduling.runnableRemove;
        const store = Lifecycle.store;
        const subjectPublicationEvent = Records.subjectPublicationEvent;
        const subjectRemove = Scheduling.subjectRemove;
        const task = Tasks.task;
        const taskCleanupComplete = Tasks.taskCleanupComplete;
        const toJson = values.toJson;
        const unclaim = Scheduling.unclaim;
        const workspaceContentCustody = Programs.workspaceContentCustody;
        const workspaceIds = Recovery.workspaceIds;
        const workspaceProgram = Programs.workspaceProgram;
        const workspaceValueReference = Contexts.workspaceValueReference;
        const workspaceWork = Programs.workspaceWork;
        const writeWorkspaceWork = publication_ops.writeWorkspaceWork;
        const equal = std.meta.eql;
        const freezeWorkspaceWork = Access.freezeWorkspaceWork;
        pub fn pumpRoot(self: *Self, a: std.mem.Allocator, initial: state.Task) anyerror!Step {
            if (initial.cancellation == null) try Observations.requireRuntimePolicy(
                self,
                a,
                initial.id,
                initial.controller_runtime,
            );
            const driver = try resident(self, a, initial);
            var decoded = try decodeOwned(
                data.invocation.Control,
                a,
                self.active.?.root_control orelse return error.CorruptState,
            );
            defer decoded.deinit();
            const control = decoded.value;
            const consumed = try rootConsumed(self, a, initial, control);
            if (!try rootCutReady(self, driver)) return .progressed;
            // Publication is transactional too. Keep the completed-cut phase
            // on failure so retry cannot apply the accepted command twice.
            const publication = try driver.drive(a, .none, 0);
            self.allocator.free(self.active.?.root_control.?);
            self.active.?.root_control = null;
            self.active.?.root_cut_ready = false;
            const encoded = publication.outcome;
            defer a.free(encoded);
            // Kosmos may now be ahead of storage. Any failure below fences all
            // further effects; restart uses the old checkpoint and saved reply.
            errdefer store(self).fence();
            var outcome = try data.invocation.decode(data.invocation.Outcome, a, encoded);
            defer outcome.deinit();
            if (outcome.value == .needs_capacity) return error.Capacity;
            var checked_output: ?Decoded(Types.Output) = null;
            defer if (checked_output) |*checked| checked.deinit();
            var checked_failure: ?Decoded(Types.Failure) = null;
            defer if (checked_failure) |*checked| checked.deinit();
            if (outcome.value == .completed) {
                const output = outcome.value.completed;
                checked_output =
                    decodeRootResult(self, Types.Output, a, initial, output) catch |err| {
                        if (err != error.InvalidResultReference) return err;
                        return rejectResult(self, a, initial, driver);
                    };
            } else if (outcome.value == .failed) {
                const failure = outcome.value.failed.value;
                checked_failure =
                    decodeRootResult(self, Types.Failure, a, initial, failure) catch |err| {
                        if (err != error.InvalidResultReference) return err;
                        return rejectResult(self, a, initial, driver);
                    };
            }
            return publishRootCut(
                self,
                a,
                initial,
                driver,
                control,
                consumed,
                publication.checkpoint,
                encoded,
                outcome.value,
                checked_output,
                checked_failure,
            );
        }
        fn rootCutReady(self: *Self, driver: *evaluator.Driver) !bool {
            // Physical pumping is transactional. An allocation failure leaves
            // the accepted operation live and retryable without fencing storage.
            if (!self.active.?.root_cut_ready) {
                var progress = try driver.pump(65536);
                defer progress.deinit();
                if (progress == .suspended) return false;
                if (progress != .event or progress.event.value != .cut)
                    return error.InvalidRuntimeProgress;
                self.active.?.root_cut_ready = true;
            }
            return true;
        }
        fn decodeRootResult(
            self: *Self,
            comptime T: type,
            a: std.mem.Allocator,
            initial: state.Task,
            bytes: []const u8,
        ) !Decoded(T) {
            var decoded = try decodeOwned(T, a, bytes);
            errdefer decoded.deinit();
            try validateResult(self, T, a, initial, decoded.value);
            return decoded;
        }
        fn consumeRootOccurrence(
            self: *Self,
            a: std.mem.Allocator,
            value: *state.Task,
            prior: occurrence.Occurrence,
        ) !void {
            try store(self).putRecord(
                occurrence.Occurrence,
                "occurrence",
                prior.id,
                value.id,
                prior,
            );
            const question_id: ?state.Digest = switch (prior.state.admitted) {
                .reply => |acquired| if (acquired.answer) |answer| answer.question else null,
                .cancelled => |waiting| if (waiting) |question| question.question else null,
            };
            if (question_id) |id| {
                var saved = try record(self, state.Question, a, "question", id, value.id);
                defer saved.deinit();
                saved.value.retired = true;
                try store(self).putRecord(state.Question, "question", id, value.id, saved.value);
            }
            if (value.messages.items.len != 0) {
                const message_id = value.messages.items[0];
                var saved =
                    try record(self, state.Message, a, "message", message_id, value.id);
                defer saved.deinit();
                if (saved.value.disposition == .acquired and
                    saved.value.occurrence != null and
                    same(&saved.value.occurrence.?, &prior.id))
                {
                    saved.value.disposition = .consumed;
                    try store(self).putRecord(
                        state.Message,
                        "message",
                        message_id,
                        value.id,
                        saved.value,
                    );
                    value.messages.items = value.messages.items[1..];
                    try messageEvent(self, a, value, .message_consumed, saved.value);
                }
            }
        }
        fn publishRootRequest(
            self: *Self,
            a: std.mem.Allocator,
            value: *state.Task,
            pending: anytype,
        ) !void {
            var request = try data.invocation.decode(data.invocation.Request, a, pending.request);
            defer request.deinit();
            var id: state.Digest = undefined;
            try self.io.randomSecure(&id);
            const next: occurrence.Occurrence = .{
                .id = id,
                .task = value.id,
                .request = request.value.request_identity,
                .request_object = try store(self).putObject(pending.request),
            };
            try store(self).createRecord(occurrence.Occurrence, "occurrence", id, value.id, next);
            const interaction =
                try controllerRequest(self, a, value.*, id, request.value);
            try store(self).createRecord(
                workspace.ExecutionRoute,
                "execution_route",
                id,
                value.id,
                .{
                    .id = id,
                    .task = value.id,
                    .work = null,
                    .image = try rootImage(self, a, value.*),
                    .program_identity = request.value.binding.program_identity,
                    .controller = value.controller,
                    .controller_epoch = value.controller_epoch,
                    .interaction = interaction,
                },
            );
            value.current_occurrence = id;
            value.outcome_kind = .requested;
        }
        fn publishRootOutcome(
            self: *Self,
            a: std.mem.Allocator,
            value: *state.Task,
            outcome: data.invocation.Outcome,
            checked_output: ?Decoded(Types.Output),
            checked_failure: ?Decoded(Types.Failure),
        ) !void {
            switch (outcome) {
                .progressed => value.outcome_kind = .progressed,
                .yielded => value.outcome_kind = .yielded,
                .requested => |pending| try publishRootRequest(self, a, value, pending),
                .completed => |bytes| {
                    value.outcome_kind = .completed;
                    value.result = try store(self).putObject(bytes);
                    try clientResult(
                        self,
                        Types.Output,
                        a,
                        value,
                        Types.output_schema_id,
                        checked_output.?.value,
                    );
                    try event(self, value, .completed, "{}");
                },
                .failed => {
                    value.outcome_kind = .failed;
                    value.result = value.outcome;
                    try clientResult(
                        self,
                        Types.Failure,
                        a,
                        value,
                        Types.failure_schema_id,
                        checked_failure.?.value,
                    );
                    try event(self, value, .failed, "{}");
                },
                .cancelled => {
                    value.outcome_kind = .cancelled;
                    value.result = value.outcome;
                    try event(self, value, .cancelled, "{}");
                },
                .needs_capacity => unreachable,
            }
        }
        fn retireRootMessages(self: *Self, a: std.mem.Allocator, value: *state.Task) !void {
            value.schedule = .parked;
            for (value.messages.items) |id| {
                var saved = try record(self, state.Message, a, "message", id, value.id);
                defer saved.deinit();
                saved.value.disposition = .not_consumed;
                try store(self).putRecord(state.Message, "message", id, value.id, saved.value);
                try messageEvent(self, a, value, .message_not_consumed, saved.value);
            }
            value.messages.items = &.{};
        }
        fn settleTerminalRoot(self: *Self, a: std.mem.Allocator, value: state.Task) !void {
            runnableRemove(self, value.id);
            const children = try workspaceIds(self, a, value.id);
            defer a.free(children);
            for (children) |child_id| {
                if (!try hasLocalCustody(self, a, value.id, child_id)) continue;
                var child = try workspaceWork(self, a, value.id, child_id);
                defer child.deinit();
                if (child.value.cancellation == null and !child.value.terminal()) {
                    try control_ops.parkWorkspaceOnClose(self, a, value.id, child_id);
                    subjectRemove(self, .{ .task = value.id, .work = child_id });
                }
            }
            if (try taskCleanupComplete(self, a, value)) unclaim(self, value.id);
        }
        fn publishRootCut(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            driver: *evaluator.Driver,
            control: data.invocation.Control,
            consumed: ?occurrence.Occurrence,
            checkpoint: []const u8,
            encoded: []const u8,
            outcome: data.invocation.Outcome,
            checked_output: ?Decoded(Types.Output),
            checked_failure: ?Decoded(Types.Failure),
        ) !Step {
            var value = initial;
            value.revision = try std.math.add(u64, value.revision, 1);
            value.execution_revision = try std.math.add(u64, value.execution_revision, 1);
            value.current_occurrence = null;
            value.schedule = .active;
            value.blocker = null;
            if (control == .cancel) value.cancellation_applied = true;
            try store(self).begin();
            defer store(self).rollback();
            value.checkpoint = try store(self).putObject(checkpoint);
            value.outcome = try store(self).putObject(encoded);
            try subjectPublicationEvent(
                self,
                &value,
                .execution,
                "{}",
                &.{},
                &.{},
                null,
                null,
                .{
                    .before = .from(initial),
                    .after = .from(value),
                },
            );
            // Terminal state has no remaining guest cleanup. Its checkpoint
            // and outcome are now owned by the transaction, so release the
            // physical evaluator before materializing potentially much larger
            // client JSON. Failure below still fences the uncommitted owner;
            // restart uses the prior durable cut and acquired reply.
            if (outcome == .completed or outcome == .failed or outcome == .cancelled) {
                try driver.close();
                try driver.destroy();
                self.active = null;
            }
            if (consumed) |prior| try consumeRootOccurrence(self, a, &value, prior);
            try publishRootOutcome(self, a, &value, outcome, checked_output, checked_failure);
            if (value.terminal()) try retireRootMessages(self, a, &value);
            try putRootOperation(self, a, .{
                .id = rootIdentity(value.id),
                .task = value.id,
                .execution_revision = value.execution_revision,
                .pending = null,
            });
            try persist(self, a, value, initial.revision, "world.advance", .preserve);
            if (self.active) |*active| {
                active.outer_operation = null;
                active.execution_revision = value.execution_revision;
            }
            if (value.terminal()) try settleTerminalRoot(self, a, value);
            return .progressed;
        }
        fn rejectResult(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            driver: *evaluator.Driver,
        ) !Step {
            try driver.close();
            try driver.destroy();
            self.active = null;
            var value = initial;
            value.revision = try std.math.add(u64, value.revision, 1);
            value.blocker = .denied;
            value.schedule = .parked;
            try store(self).begin();
            defer store(self).rollback();
            try putRootOperation(self, a, .{
                .id = rootIdentity(value.id),
                .task = value.id,
                .execution_revision = value.execution_revision,
                .pending = null,
            });
            try event(self, &value, .blocked, "{\"reason\":\"InvalidResultReference\"}");
            try persist(self, a, value, initial.revision, "task.blocked", .preserve);
            runnableRemove(self, value.id);
            return .waiting;
        }
        fn clientResult(
            self: *Self,
            comptime T: type,
            a: std.mem.Allocator,
            value: *state.Task,
            schema_id: []const u8,
            result: T,
        ) !void {
            const bytes = try canonicalBounded(
                self.allocator,
                try toJson(T, a, result),
                try store(self).database.blobLimit(),
            );
            defer self.allocator.free(bytes);
            value.client_result = try store(self).putObject(bytes);
            if (bytes.len > 60 * 1024) {
                var id: state.Digest = undefined;
                try self.io.randomSecure(&id);
                const artifact: state.Artifact = .{
                    .id = id,
                    .task = value.id,
                    .value = value.client_result.?,
                    .media_type = .{ .bytes = "application/json" },
                    .schema_id = try name(schema_id),
                };
                try store(self).createRecord(state.Artifact, "artifact", id, value.id, artifact);
                value.result_artifact = id;
            }
        }
        const ResultAdmission = resultAdmissionType();
        fn resultAdmissionType() type {
            return struct {
                service: *Self,
                allocator: std.mem.Allocator,
                task: state.TaskId,
                profile: state.Digest,

                pub fn projected(this: @This(), reference: anytype, identity: []const u8) ![]u8 {
                    const host = this.service;
                    const a = this.allocator;
                    const owners =
                        try store(host).projectionOwners(a, this.task, reference.digest);
                    defer a.free(owners);
                    var parent = try task(host, a, this.task);
                    defer parent.deinit();
                    for (owners) |owner| {
                        if (owner.object.bytes != reference.bytes) continue;
                        var attempt = try record(
                            host,
                            state.Attempt,
                            a,
                            "attempt",
                            owner.attempt,
                            this.task,
                        );
                        defer attempt.deinit();
                        if (!equal(
                            attempt.value.profile,
                            parent.value.profile,
                        )) return error.CorruptState;
                        const bytes =
                            try store(host).object(a, attempt.value.request, null);
                        defer a.free(bytes);
                        var request = try data.invocation.decode(data.invocation.Request, a, bytes);
                        defer request.deinit();
                        var pending = try record(
                            host,
                            occurrence.Occurrence,
                            a,
                            "occurrence",
                            attempt.value.occurrence,
                            this.task,
                        );
                        defer pending.deinit();
                        const entry = try host.handlers.resolve(
                            request.value,
                            try occurrenceImage(host, a, parent.value, pending.value),
                        );
                        if (same(
                            entry.declaration.identity,
                            identity,
                        )) return store(host).object(a, owner.object, null);
                    }
                    return error.InvalidResultReference;
                }
                pub fn workspaceReference(
                    this: @This(),
                    ref: wc.Ref,
                    kind: @FieldType(wc.Ref, "kind"),
                ) !void {
                    const id = wp.identity(ref, kind) catch return error.InvalidResultReference;
                    const custody_id =
                        try workspaceContentCustody(this.allocator, this.task, id);
                    switch (kind) {
                        .program => {
                            const bytes = (try store(this.service).recordBytes(
                                this.allocator,
                                "workspace_program",
                                custody_id,
                                this.task,
                            )) orelse return error.InvalidResultReference;
                            this.allocator.free(bytes);
                            var program = try workspaceProgram(
                                this.service,
                                this.allocator,
                                this.task,
                                id,
                            );
                            defer program.deinit();
                        },
                        .value => {
                            const bytes = (try store(this.service).recordBytes(
                                this.allocator,
                                "workspace_value",
                                custody_id,
                                this.task,
                            )) orelse return error.InvalidResultReference;
                            this.allocator.free(bytes);
                            _ = try workspaceValueReference(
                                this.service,
                                this.allocator,
                                this.task,
                                ref,
                            );
                        },
                        else => return error.InvalidResultReference,
                    }
                }
            };
        }
        pub fn validateResult(
            self: *Self,
            comptime T: type,
            a: std.mem.Allocator,
            value: state.Task,
            result: T,
        ) !void {
            if (comptime T == Types.Output and @hasDecl(Types, "validateOutput")) {
                try Types.validateOutput(
                    ResultAdmission{
                        .service = self,
                        .allocator = a,
                        .task = value.id,
                        .profile = value.profile.digest,
                    },
                    result,
                );
            }
        }
        pub fn occurrenceImage(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            pending: occurrence.Occurrence,
        ) !state.Digest {
            var route = try record(
                self,
                workspace.ExecutionRoute,
                a,
                "execution_route",
                pending.id,
                parent.id,
            );
            defer route.deinit();
            if (!equal(route.value.work, pending.work) or
                !equal(route.value.residual, pending.residual) or
                !equal(route.value.task, parent.id) or
                !equal(route.value.id, pending.id))
                return error.CorruptState;
            if (pending.work) |id| {
                var work = try workspaceWork(self, a, parent.id, id);
                defer work.deinit();
                var program = try workspaceProgram(self, a, parent.id, work.value.program);
                defer program.deinit();
                if (!equal(program.value.description.image, route.value.image) or !equal(
                    work.value.delegation,
                    route.value.delegation,
                )) return error.CorruptState;
            } else if (!equal(
                try rootRouteImage(self, a, parent, route.value),
                route.value.image,
            )) return error.CorruptState;
            return route.value.program_identity;
        }
        pub fn occurrenceSubject(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            pending: occurrence.Occurrence,
        ) !OccurrenceSubject {
            var route = try record(
                self,
                workspace.ExecutionRoute,
                a,
                "execution_route",
                pending.id,
                parent.id,
            );
            defer route.deinit();
            if (!equal(route.value.work, pending.work) or
                !equal(route.value.residual, pending.residual) or
                !equal(route.value.task, parent.id) or
                !equal(route.value.id, pending.id))
                return error.CorruptState;
            if (pending.work != null) return workspaceOccurrenceSubject(
                self,
                a,
                parent,
                pending,
                route.value,
            );
            if (pending.residual) |id| {
                if (pending.work != null) return error.CorruptState;
                var residual = try record(
                    self,
                    state.ControllerResidual,
                    a,
                    "controller_residual",
                    id,
                    parent.id,
                );
                defer residual.deinit();
                if (!residual.value.cancellation_applied or !equal(
                    residual.value.current_occurrence,
                    pending.id,
                ) or !equal(route.value.controller, residual.value.controller) or !equal(
                    try rootRouteImage(self, a, parent, route.value),
                    route.value.image,
                )) return error.StaleOccurrence;
                return .{
                    .image = route.value.program_identity,
                    .cancelling = true,
                    .cleanup = true,
                };
            }
            if (!equal(parent.current_occurrence, pending.id) or !equal(
                parent.controller,
                route.value.controller,
            )) return error.StaleOccurrence;
            if (!equal(try rootImage(self, a, parent), route.value.image) or !equal(
                route.value.program_identity,
                try rootProgramIdentity(self, a, parent),
            )) return error.CorruptState;
            return .{
                .image = route.value.program_identity,
                .cancelling = parent.cancellation != null,
                .cleanup = parent.cancellation_applied,
            };
        }
        fn workspaceOccurrenceSubject(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            pending: occurrence.Occurrence,
            route: workspace.ExecutionRoute,
        ) !OccurrenceSubject {
            const id = pending.work.?;

            var work = try workspaceWork(self, a, parent.id, id);
            defer work.deinit();
            if (!equal(work.value.current_occurrence, pending.id))
                return error.StaleOccurrence;
            var program = try workspaceProgram(self, a, parent.id, work.value.program);
            defer program.deinit();
            if (!equal(
                program.value.description.image,
                route.image,
            )) return error.CorruptState;
            return .{
                .image = route.program_identity,
                .cancelling = work.value.cancellation != null,
                .cleanup = work.value.cancellation_applied,
            };
        }
        pub fn effectSchedule(
            self: *Self,
            a: std.mem.Allocator,
            parent: *state.Task,
            pending: occurrence.Occurrence,
            schedule: state.Schedule,
            blocker: ?state.Blocker,
        ) !void {
            // Inside the same transaction as its occurrence. Child accounting is
            // visible in the task journal without changing the root continuation.
            if (pending.residual) |id| {
                var residual = try record(
                    self,
                    state.ControllerResidual,
                    a,
                    "controller_residual",
                    id,
                    parent.id,
                );
                defer residual.deinit();
                if (!equal(residual.value.current_occurrence, pending.id))
                    return error.StaleOccurrence;
                residual.value.schedule = schedule;
                residual.value.blocker = blocker;
                try store(self).putRecord(
                    state.ControllerResidual,
                    "controller_residual",
                    id,
                    parent.id,
                    residual.value,
                );
                try residualProgressEvent(self, a, parent, residual.value);
                return;
            }
            const id = pending.work orelse return;
            var work = try retainedWorkspaceWork(self, a, parent.id, id);
            defer work.deinit();
            if (!equal(work.value.current_occurrence, pending.id))
                return error.StaleOccurrence;
            // Completion makes work eligible; it does not revoke a later park.
            if (schedule != .queued or
                work.value.schedule != .parked) work.value.schedule = schedule;
            work.value.blocker = blocker;
            work.value.event_watermark = try std.math.add(u64, parent.event_high, 1);
            try writeWorkspaceWork(self, &work.value, .replace);
            const event_data = try std.fmt.allocPrint(a, "{{\"workspace_id\":\"{s}\"}}", .{
                std.fmt.bytesToHex(id, .lower),
            });
            defer a.free(event_data);
            const observed =
                try freezeWorkspaceWork(self, a, parent.id, try wp.reference(a, .work, id), true);
            const snapshot = try contracts.encodeOwned(workspace.WorkObservation, a, observed);
            defer a.free(snapshot);
            _ = try store(self).putObject(snapshot);
            try publicationEvent(
                self,
                parent,
                .workspace_progress,
                event_data,
                &.{try Access.workPublication(a, observed)},
                null,
            );
        }
        pub fn persistOccurrence(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            previous: u64,
            transition: []const u8,
            pending: occurrence.Occurrence,
            wake: bool,
        ) !void {
            var subject: ?workspace.Subject = null;
            if (wake) if (pending.residual) |id| {
                var residual = try record(
                    self,
                    state.ControllerResidual,
                    a,
                    "controller_residual",
                    id,
                    parent.id,
                );
                defer residual.deinit();
                if (residual.value.schedule != .parked) subject = .{
                    .task = parent.id,
                    .residual = id,
                };
            } else if (pending.work) |id| {
                var work = try workspaceWork(self, a, parent.id, id);
                defer work.deinit();
                if (work.value.schedule != .parked) subject = .{ .task = parent.id, .work = id };
            } else {
                subject = .{ .task = parent.id };
            };
            try persistScheduled(
                self,
                a,
                parent,
                previous,
                transition,
                .preserve,
                if (subject) |value| &.{value} else &.{},
            );
        }
        pub fn blockedOccurrence(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: occurrence.Occurrence,
            reason: state.Blocker,
        ) !Step {
            if (pending.work == null and pending.residual == null) return blocked(
                self,
                a,
                initial,
                reason,
            );
            var parent = initial;
            parent.revision = try std.math.add(u64, parent.revision, 1);
            try store(self).begin();
            defer store(self).rollback();
            try effectSchedule(self, a, &parent, pending, .parked, reason);
            try persist(self, a, parent, initial.revision, "effect.blocked", .preserve);
            subjectRemove(self, .{
                .task = parent.id,
                .work = pending.work,
                .residual = pending.residual,
            });
            return .waiting;
        }
    };
}
