const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const workspace = @import("../workspace_state.zig");
const build_job = @import("../workspace_build.zig");
const wp = @import("../workspace_projection.zig");
const task_types = @import("types.zig");
const CompilerReadPosition = task_types.CompilerReadPosition;
const WorkspaceAdmission = task_types.WorkspaceAdmission;
const operation = task_types.operation;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const controllerAt = Controller.controllerAt;
        const occurrenceImage = Root.occurrenceImage;
        const record = Records.record;
        const store = Lifecycle.store;
        const validateControllerReadCut = Replay.validateControllerReadCut;
        const validateResidualObservation = Residuals.validateResidualObservation;
        const workspaceInterruptedAt = Access.workspaceInterruptedAt;
        const Residuals = @import("controller_residuals.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Root = @import("root_execution.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Replay = @import("workspace_replay.zig").Operations(Types, Self);
        pub fn workspacePublicationAt(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
            watermark: u64,
        ) !u64 {
            var query = try store(self).database.prepare(
                "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                    "ERE e.task=? AND e.seq<=? ORDER BY e.seq DESC",
                &.{ .{ .blob = &task_id }, .{
                    .integer = std.math.cast(i64, watermark) orelse return error.InvalidArchive,
                } },
            );
            defer query.deinit();
            while (try query.step() == .row) {
                var saved = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                defer saved.deinit();
                for (saved.value.workspace_publications.items) |item| if (std.meta.eql(
                    item.work,
                    id,
                )) return saved.value.seq;
            }
            return error.InvalidArchive;
        }
        pub fn residualPublicationAt(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
            watermark: u64,
        ) !state.ControllerResidualObservation {
            var query = try store(self).database.prepare(
                "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                    "ERE e.task=? AND e.seq<=? ORDER BY e.seq DESC",
                &.{ .{ .blob = &task_id }, .{
                    .integer = std.math.cast(i64, watermark) orelse return error.InvalidArchive,
                } },
            );
            defer query.deinit();
            while (try query.step() == .row) {
                var saved = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                defer saved.deinit();
                for (saved.value.residual_publications.items) |item| if (std.meta.eql(
                    item.value.id,
                    id,
                )) return item.value;
            }
            return error.InvalidArchive;
        }
        fn residualWaitReadyAt(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            id: state.Digest,
            watermark: u64,
        ) !bool {
            var waiting =
                try record(self, workspace.Wait, a, "workspace_wait", id, parent.id);
            defer waiting.deinit();
            if (try workspaceInterruptedAt(self, a, parent.id, watermark)) return true;
            for (waiting.value.selection.works.items) |ref| {
                const work = try wp.identity(ref, .work);
                const seq = try workspacePublicationAt(self, a, parent.id, work, watermark);
                if (seq > waiting.value.selection.after) return true;
                var query = try store(self).database.prepare(
                    "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                        "ERE e.task=? AND e.seq=?",
                    &.{ .{ .blob = &parent.id }, .{ .integer = @intCast(seq) } },
                );
                defer query.deinit();
                if (try query.step() != .row) return error.InvalidArchive;
                var saved = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                defer saved.deinit();
                for (saved.value.workspace_publications.items) |item| if (std.meta.eql(
                    item.work,
                    work,
                )) {
                    if (item.control.outcome == .completed or item.control.outcome == .failed or
                        item.control.outcome == .cancelled)
                        return true;
                };
            }
            return false;
        }
        fn residualRecoveryAt(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            id: state.Digest,
            revision: u64,
        ) !bool {
            var query = try store(self).database.prepare(
                "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body W" ++
                    "HERE r.task=? AND r.kind='reconciliation'",
                &.{.{ .blob = &parent.id }},
            );
            defer query.deinit();
            while (try query.step() == .row) {
                var saved = try contracts.decodeOwned(state.Reconciliation, a, try query.bytes(0));
                defer saved.deinit();
                if (saved.value.admission_revision == revision and std.meta.eql(
                    saved.value.occurrence,
                    id,
                ) and saved.value.owner_epoch != null) return true;
            }
            return false;
        }
        fn residualRecoveredAt(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            pending: occurrence.Occurrence,
            revision: u64,
        ) !bool {
            const attempt = switch (pending.state) {
                .captured, .not_sent => |value| value.id,
                .settled_reply => |value| value.attempt,
                else => return error.InvalidArchive,
            };
            var query = try store(self).database.prepare(
                "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body W" ++
                    "HERE r.task=? AND r.kind='reconciliation'",
                &.{.{ .blob = &parent.id }},
            );
            defer query.deinit();
            while (try query.step() == .row) {
                var saved = try contracts.decodeOwned(state.Reconciliation, a, try query.bytes(0));
                defer saved.deinit();
                const value = saved.value;
                if (!std.meta.eql(value.occurrence, pending.id) or !std.meta.eql(
                    value.attempt,
                    attempt,
                ) or value.admission_revision > revision) continue;
                const matches = switch (pending.state) {
                    .captured => blk: {
                        if (value.outcome == .capture_admitted) break :blk true;
                        if (value.outcome != .reply_settled) break :blk false;
                        const ref = value.previous orelse break :blk false;
                        var previous = try contracts.decodeOwned(
                            state.Reconciliation,
                            a,
                            try store(self).object(a, ref, null),
                        );
                        defer previous.deinit();
                        break :blk std.meta.eql(previous.value.id, value.id) and
                            std.meta.eql(previous.value.task, parent.id) and std.meta.eql(
                            previous.value.occurrence,
                            pending.id,
                        ) and std.meta.eql(previous.value.attempt, attempt) and
                            previous.value.outcome == .capture_admitted;
                    },
                    .not_sent => value.outcome == .not_sent,
                    .settled_reply => |reply| value.outcome == .reply_settled and
                        std.meta.eql(value.outcome.reply_settled.digest, reply.reply),
                    else => unreachable,
                };
                if (matches) return true;
            }
            return false;
        }
        fn validateResidualDelivery(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            before: occurrence.Occurrence,
            after: occurrence.Occurrence,
            revision: u64,
        ) !void {
            var validation = ResidualDeliveryValidation{
                .self = self,
                .a = a,
                .parent = parent,
                .before = before,
                .after = after,
                .revision = revision,
                .binding = undefined,
            };
            return validation.run();
        }
        const ResidualDeliveryValidation = residualDeliveryValidationType();
        fn residualDeliveryValidationType() type {
            return struct {
                self: *Self,
                a: std.mem.Allocator,
                parent: state.Task,
                before: occurrence.Occurrence,
                after: occurrence.Occurrence,
                revision: u64,
                binding: occurrence.Binding,
                fn run(ctx: *@This()) !void {
                    if (std.meta.eql(ctx.before, ctx.after)) return;
                    ctx.binding = .{
                        .id = ctx.before.id,
                        .task = ctx.parent.id,
                        .residual = ctx.before.residual,
                        .request = ctx.before.request,
                    };
                    const expected = switch (ctx.after.state) {
                        .dispatching => |attempt| occurrence.dispatch(
                            ctx.before,
                            ctx.binding,
                            attempt.id,
                            false,
                            true,
                        ) catch return error.InvalidArchive,
                        .awaiting => |waiting| occurrence.awaiting(
                            ctx.before,
                            ctx.binding,
                            waiting,
                            false,
                        ) catch return error.InvalidArchive,
                        .unknown => |attempt| occurrence.unknown(
                            ctx.before,
                            ctx.binding,
                            attempt.id,
                        ) catch return error.InvalidArchive,
                        .not_sent => |attempt| try ctx.deliveryNotSent(attempt),
                        .captured => |attempt| try ctx.deliveryCaptured(attempt),
                        .settled_reply => |reply| try ctx.deliverySettledReply(reply),
                        .ready, .admitted => return error.InvalidArchive,
                    };
                    if (!std.meta.eql(expected, ctx.after)) return error.InvalidArchive;
                }

                fn deliveryNotSent(
                    ctx: *@This(),
                    attempt: @FieldType(@FieldType(occurrence.Occurrence, "state"), "not_sent"),
                ) !occurrence.Occurrence {
                    if (ctx.before.state == .unknown) {
                        if (!try residualRecoveredAt(
                            ctx.self,
                            ctx.a,
                            ctx.parent,
                            ctx.after,
                            ctx.revision,
                        )) return error.InvalidArchive;
                        return occurrence.recoveredNotSent(
                            ctx.before,
                            ctx.binding,
                            attempt.id,
                        ) catch return error.InvalidArchive;
                    }
                    return occurrence.notSent(ctx.before, ctx.binding, attempt.id) catch
                        return error.InvalidArchive;
                }

                fn deliveryCaptured(
                    ctx: *@This(),
                    attempt: @FieldType(@FieldType(occurrence.Occurrence, "state"), "captured"),
                ) !occurrence.Occurrence {
                    if (ctx.before.state == .unknown) {
                        if (!try residualRecoveredAt(
                            ctx.self,
                            ctx.a,
                            ctx.parent,
                            ctx.after,
                            ctx.revision,
                        )) return error.InvalidArchive;
                        return occurrence.recoveredCapture(
                            ctx.before,
                            ctx.binding,
                            attempt.id,
                        ) catch return error.InvalidArchive;
                    }
                    return occurrence.captured(ctx.before, ctx.binding, attempt.id) catch
                        return error.InvalidArchive;
                }

                fn deliverySettledReply(
                    ctx: *@This(),
                    reply: @FieldType(@FieldType(occurrence.Occurrence, "state"), "settled_reply"),
                ) !occurrence.Occurrence {
                    if (reply.answer) |answer| return occurrence.answered(
                        ctx.before,
                        ctx.binding,
                        answer.question,
                        answer.pending_digest,
                        answer.digest,
                        reply.reply,
                        false,
                    ) catch return error.InvalidArchive;
                    var dispatched = ctx.before;
                    if (ctx.before.state == .ready) {
                        const bytes =
                            try store(ctx.self).object(ctx.a, ctx.before.request_object, null);
                        defer ctx.a.free(bytes);
                        var request =
                            try data.invocation.decode(data.invocation.Request, ctx.a, bytes);
                        defer request.deinit();
                        const entry = try ctx.self.handlers.resolve(
                            request.value,
                            try occurrenceImage(ctx.self, ctx.a, ctx.parent, ctx.before),
                        );
                        if (entry.declaration.kind != .workspace) return error.InvalidArchive;
                        dispatched = occurrence.dispatch(
                            ctx.before,
                            ctx.binding,
                            reply.attempt,
                            false,
                            true,
                        ) catch return error.InvalidArchive;
                    } else if (ctx.before.state == .unknown and !try residualRecoveredAt(
                        ctx.self,
                        ctx.a,
                        ctx.parent,
                        ctx.after,
                        ctx.revision,
                    )) return error.InvalidArchive;
                    return occurrence.acquired(
                        dispatched,
                        ctx.binding,
                        reply.attempt,
                        reply.reply,
                    ) catch return error.InvalidArchive;
                }
            };
        }
        pub fn validateResidualPublication(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            event_value: state.Event,
            item: state.ResidualPublication,
            prior: ?state.ResidualPublication,
            command: ?workspace.PublicationCommand,
            admission: ?WorkspaceAdmission,
        ) !void {
            var validation = ResidualPublicationValidation{
                .self = self,
                .a = a,
                .parent = parent,
                .event_value = event_value,
                .item = item,
                .prior = prior,
                .command = command,
                .admission = admission,
                .value = item.value,
                .expected = undefined,
            };
            return validation.run();
        }
        const ResidualPublicationValidation = residualPublicationValidationType();
        fn residualPublicationValidationType() type {
            return struct {
                self: *Self,
                a: std.mem.Allocator,
                parent: state.Task,
                event_value: state.Event,
                item: state.ResidualPublication,
                prior: ?state.ResidualPublication,
                command: ?workspace.PublicationCommand,
                admission: ?WorkspaceAdmission,
                value: state.ControllerResidualObservation,
                expected: state.ControllerResidualObservation,
                fn run(ctx: *@This()) !void {
                    if (!std.meta.eql(ctx.value.task, ctx.parent.id)) return error.InvalidArchive;
                    try ctx.occurrenceIdentity();
                    if (ctx.prior) |before| {
                        if (before.value.outcome_kind == .completed or
                            before.value.outcome_kind == .failed or
                            before.value.outcome_kind == .cancelled)
                            return error.InvalidArchive;
                        ctx.expected = before.value;
                        if (ctx.command) |selected| try ctx.selectedCommand(
                            before,
                            selected,
                        ) else try ctx.progress(before);
                    } else {
                        try ctx.initialPublication();
                    }
                }

                fn occurrenceIdentity(ctx: *@This()) !void {
                    if (ctx.item.occurrence) |pending| {
                        if (!std.meta.eql(ctx.value.current_occurrence, pending.id) or
                            !std.meta.eql(pending.task, ctx.parent.id) or pending.work != null or
                            (ctx.value.cancellation_applied and !std.meta.eql(
                                pending.residual,
                                ctx.value.id,
                            ))) return error.InvalidArchive;
                        var current = try record(
                            ctx.self,
                            occurrence.Occurrence,
                            ctx.a,
                            "occurrence",
                            pending.id,
                            ctx.parent.id,
                        );
                        defer current.deinit();
                        if (!std.meta.eql(pending.request, current.value.request) or !std.meta.eql(
                            pending.request_object,
                            current.value.request_object,
                        )) return error.InvalidArchive;
                        const acquired: ?occurrence.Acquired = switch (pending.state) {
                            .settled_reply => |reply| reply,
                            .admitted => |settled| if (settled == .reply) settled.reply else null,
                            else => null,
                        };
                        if (acquired) |acquired_expected| {
                            const actual = switch (current.value.state) {
                                .settled_reply => |reply| reply,
                                .admitted => |settled| if (settled ==
                                    .reply) settled.reply else return error.InvalidArchive,
                                else => return error.InvalidArchive,
                            };
                            if (!std.meta.eql(acquired_expected, actual))
                                return error.InvalidArchive;
                        }
                    } else if (ctx.value.current_occurrence != null) return error.InvalidArchive;
                }

                fn initialPublication(ctx: *@This()) !void {
                    if (ctx.event_value.kind != .controller or
                        ctx.command != null or
                        ctx.value.execution_revision == 0 or
                        ctx.value.control_revision != 1 or
                        ctx.value.cancellation_applied or
                        ctx.value.schedule != .queued or
                        ctx.value.blocker != null)
                        return error.InvalidArchive;
                    var succession = try record(
                        ctx.self,
                        state.ControllerSuccession,
                        ctx.a,
                        "controller_succession",
                        ctx.value.succession,
                        ctx.parent.id,
                    );
                    defer succession.deinit();
                    const original = succession.value;
                    if (original.phase != .activated or
                        original.activation_event != ctx.event_value.seq or
                        !std.meta.eql(original.residual, ctx.value.id) or !std.meta.eql(
                        original.predecessor,
                        ctx.value.controller,
                    ) or !std.meta.eql(original.checkpoint, ctx.value.initial_checkpoint) or
                        !std.meta.eql(original.checkpoint, ctx.value.checkpoint) or
                        !std.meta.eql(original.outcome, ctx.value.outcome) or
                        !std.meta.eql(ctx.value.current_occurrence, original.handoff))
                        return error.InvalidArchive;
                    const publication = ctx.event_value.root_publication orelse
                        return error.InvalidArchive;
                    const boot = original.boot orelse return error.InvalidArchive;
                    if (!std.meta.eql(
                        publication.after.controller,
                        try controllerAt(ctx.self, ctx.a, ctx.parent, ctx.event_value.seq),
                    ) or
                        !std.meta.eql(publication.after.checkpoint, boot.checkpoint.digest))
                        return error.InvalidArchive;
                    try validateResidualObservation(ctx.self, ctx.a, ctx.value);
                }

                fn receiptObservation(ctx: *@This(), admitted: WorkspaceAdmission) !void {
                    var observed = try contracts.decodeOwned(
                        state.ControllerResidual,
                        ctx.a,
                        try store(ctx.self).object(ctx.a, admitted.observation orelse
                            return error.InvalidArchive, null),
                    );
                    defer observed.deinit();
                    if (!std.meta.eql(
                        ctx.value,
                        state.ControllerResidualObservation.from(observed.value),
                    )) return error.InvalidArchive;
                }

                fn selectedCommand(
                    ctx: *@This(),
                    before: state.ResidualPublication,
                    selected: workspace.PublicationCommand,
                ) !void {
                    const admitted = ctx.admission orelse return error.InvalidArchive;
                    if (ctx.event_value.kind != .workspace or selected != .residual or
                        !std.meta.eql(admitted.work, ctx.value.id) or
                        selected.residual.execution != before.value.execution_revision or
                        selected.residual.control != before.value.control_revision or
                        selected.residual.command == .delegate)
                        return error.InvalidArchive;
                    ctx.expected.control_revision = std.math.add(
                        u64,
                        ctx.expected.control_revision,
                        1,
                    ) catch return error.InvalidArchive;
                    ctx.expected.schedule =
                        if (selected.residual.command == .park) .parked else .queued;
                    ctx.expected.blocker = null;
                    if (!std.meta.eql(ctx.expected, ctx.value)) return error.InvalidArchive;
                    var pending = before.occurrence;
                    if (pending) |*old| {
                        if (old.state == .unknown or old.state == .dispatching)
                            return error.InvalidArchive;
                        if (old.state == .not_sent and
                            selected.residual.command != .park) old.* = occurrence.rearm(
                            old.*,
                            .{
                                .id = old.id,
                                .task = ctx.parent.id,
                                .residual = old.residual,
                                .request = old.request,
                            },
                        ) catch return error.InvalidArchive;
                    }
                    if (!std.meta.eql(pending, ctx.item.occurrence)) return error.InvalidArchive;
                    try ctx.receiptObservation(admitted);
                }

                fn deliveryProgress(ctx: *@This(), before: state.ResidualPublication) !void {
                    const pending = ctx.item.occurrence orelse return error.InvalidArchive;
                    if (before.occurrence == null or !std.meta.eql(
                        pending.id,
                        before.occurrence.?.id,
                    )) return error.InvalidArchive;
                    try validateResidualDelivery(
                        ctx.self,
                        ctx.a,
                        ctx.parent,
                        before.occurrence.?,
                        pending,
                        ctx.event_value.revision,
                    );
                    if (ctx.value.blocker != null) {
                        if (pending.state != .ready and pending.state != .captured and
                            pending.state != .unknown and pending.state != .not_sent)
                            return error.InvalidArchive;
                        ctx.expected.schedule = .parked;
                        ctx.expected.blocker = ctx.value.blocker;
                        if (ctx.value.blocker == .waiting_workspace and
                            (pending.state != .ready or
                                !ctx.value.cancellation_applied or
                                try residualWaitReadyAt(
                                    ctx.self,
                                    ctx.a,
                                    ctx.parent,
                                    pending.id,
                                    ctx.event_value.seq - 1,
                                ))) return error.InvalidArchive;
                    } else {
                        ctx.expected.blocker = null;
                        ctx.expected.schedule = switch (pending.state) {
                            .dispatching => .active,
                            .awaiting => .parked,
                            .captured, .settled_reply => .queued,
                            .ready => blk: {
                                if (before.value.blocker != .waiting_workspace or
                                    before.value.schedule != .parked or
                                    !ctx.value.cancellation_applied or
                                    !try residualWaitReadyAt(
                                        ctx.self,
                                        ctx.a,
                                        ctx.parent,
                                        pending.id,
                                        ctx.event_value.seq - 1,
                                    )) return error.InvalidArchive;
                                break :blk .queued;
                            },
                            .unknown => blk: {
                                if (!try residualRecoveryAt(
                                    ctx.self,
                                    ctx.a,
                                    ctx.parent,
                                    pending.id,
                                    ctx.event_value.revision,
                                )) return error.InvalidArchive;
                                break :blk .queued;
                            },
                            else => return error.InvalidArchive,
                        };
                    }
                    if (!std.meta.eql(ctx.expected, ctx.value)) return error.InvalidArchive;
                }

                fn progress(ctx: *@This(), before: state.ResidualPublication) !void {
                    if (ctx.event_value.kind != .workspace_progress) return error.InvalidArchive;
                    if (ctx.value.execution_revision != before.value.execution_revision) {
                        ctx.expected.execution_revision = std.math.add(
                            u64,
                            ctx.expected.execution_revision,
                            1,
                        ) catch return error.InvalidArchive;
                        ctx.expected.checkpoint = ctx.value.checkpoint;
                        ctx.expected.outcome = ctx.value.outcome;
                        ctx.expected.outcome_kind = ctx.value.outcome_kind;
                        ctx.expected.current_occurrence = ctx.value.current_occurrence;
                        ctx.expected.cancellation_applied = true;
                        ctx.expected.schedule = if (ctx.value.outcome_kind == .completed or
                            ctx.value.outcome_kind == .failed or
                            ctx.value.outcome_kind == .cancelled) .parked else .queued;
                        if (!std.meta.eql(ctx.expected, ctx.value)) return error.InvalidArchive;
                        if (ctx.item.occurrence) |pending| if (pending.state != .ready)
                            return error.InvalidArchive;
                        try validateResidualObservation(ctx.self, ctx.a, ctx.value);
                    } else {
                        try ctx.deliveryProgress(before);
                    }
                }
            };
        }
        pub fn capturedControllerReads(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            records: []const state.ArchiveRecord,
            compiler_reads: *std.AutoHashMap(state.Digest, CompilerReadPosition),
        ) ![]state.ControllerReadCut {
            var captured_reads: std.ArrayList(state.ControllerReadCut) = .empty;
            errdefer captured_reads.deinit(a);
            for (records) |row| {
                if (row.kind != .attempt) continue;
                var attempt =
                    try record(self, state.Attempt, self.allocator, "attempt", row.id, task_id);
                defer attempt.deinit();
                if (!std.meta.eql(attempt.value.task, task_id) or
                    !std.meta.eql(attempt.value.id, row.id)) return error.InvalidArchive;
                if (attempt.value.controller_read) |read| try captured_reads.append(a, read);
                try captureCompilerRead(self, task_id, attempt.value, compiler_reads);
            }
            std.mem.sort(state.ControllerReadCut, captured_reads.items, {}, struct {
                fn less(
                    _: void,
                    left: state.ControllerReadCut,
                    right: state.ControllerReadCut,
                ) bool {
                    return left.event_watermark < right.event_watermark;
                }
            }.less);
            return captured_reads.toOwnedSlice(a);
        }
        fn captureCompilerRead(
            self: *Self,
            task_id: state.TaskId,
            attempt: state.Attempt,
            compiler_reads: *std.AutoHashMap(state.Digest, CompilerReadPosition),
        ) !void {
            if (attempt.operation == .workspace_build) {
                const bytes = try store(self).object(
                    self.allocator,
                    attempt.prepared orelse return error.InvalidArchive,
                    null,
                );
                defer self.allocator.free(bytes);
                var input = try contracts.decodeOwned(build_job.Input, self.allocator, bytes);
                defer input.deinit();
                if (input.value == .derive and input.value.derive.basis != .immutable) {
                    try captureMutableCompilerRead(
                        self,
                        task_id,
                        attempt,
                        input.value,
                        compiler_reads,
                    );
                } else if (attempt.dispatch_checkpoint != null)
                    return error.InvalidArchive;
            } else if (attempt.dispatch_checkpoint != null) return error.InvalidArchive;
        }
        fn captureMutableCompilerRead(
            self: *Self,
            task_id: state.TaskId,
            attempt: state.Attempt,
            input: build_job.Input,
            compiler_reads: *std.AutoHashMap(state.Digest, CompilerReadPosition),
        ) !void {
            const at = switch (input.derive.basis) {
                .controller => |read| read.event_watermark,
                .works => |read| read.event_watermark,
                else => return error.InvalidArchive,
            };
            try validateControllerReadCut(input.derive.basis, attempt.controller_read);
            const checkpoint = attempt.dispatch_checkpoint orelse
                return error.InvalidArchive;
            const checkpoint_bytes =
                try store(self).object(self.allocator, checkpoint, null);
            defer self.allocator.free(checkpoint_bytes);
            const request_bytes =
                try store(self).object(self.allocator, attempt.request, null);
            defer self.allocator.free(request_bytes);
            var request =
                try data.invocation.decode(data.invocation.Request, self.allocator, request_bytes);
            defer request.deinit();
            if (!std.meta.eql(
                data.invocation.stateDigest(checkpoint_bytes),
                request.value.binding.pending_state_digest,
            )) return error.InvalidArchive;
            var route = try record(
                self,
                workspace.ExecutionRoute,
                self.allocator,
                "execution_route",
                attempt.occurrence,
                task_id,
            );
            defer route.deinit();
            if (route.value.work != null or route.value.residual != null)
                return error.InvalidArchive;
            const entry = try compiler_reads.getOrPut(attempt.id);
            if (entry.found_existing) return error.InvalidArchive;
            entry.value_ptr.* = .{
                .occurrence = attempt.occurrence,
                .event_watermark = at,
                .controller_read = attempt.controller_read,
                .root = .{
                    .controller = route.value.controller,
                    .checkpoint = checkpoint.digest,
                },
            };
        }
    };
}
