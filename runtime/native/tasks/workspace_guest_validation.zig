const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const evaluator = @import("../driver.zig");
const kosmos = @import("kosmos");
const workspace = @import("../workspace_state.zig");
const task_types = @import("types.zig");
const CompilerFact = task_types.CompilerFact;
const Work = task_types.Work;
const same = task_types.same;

var guest_segment_proofs: @import("../guest_segment_proofs.zig") = .{};

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const inspectionRuntime = Inspection.inspectionRuntime;
        const samePublication = Access.samePublication;
        const store = Lifecycle.store;
        const validateHistoricalOccurrence = Replay.validateHistoricalOccurrence;
        const workPublication = Access.workPublication;
        const workspaceProgram = Programs.workspaceProgram;
        const workspaceWork = Programs.workspaceWork;
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Inspection = @import("workspace_inspection.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Replay = @import("workspace_replay.zig").Operations(Types, Self);
        pub fn validateWorkspaceGuestWork(
            self: *Self,
            task_id: state.TaskId,
            item: state.WorkPublication,
            prior: ?state.WorkPublication,
            command: ?workspace.PublicationCommand,
            prefix: *const @import("../workspace_observers.zig").PublicationPrefix,
        ) !void {
            var validation = GuestWorkValidation{
                .self = self,
                .task_id = task_id,
                .item = item,
                .prior = prior,
                .command = command,
                .prefix = prefix,
                .a = undefined,
                .work = undefined,
                .control = .none,
                .quantum = 256,
                .frozen_control = null,
                .initial_checkpoint = null,
            };
            return validation.run();
        }
        const GuestWorkValidation = guestWorkValidationType();
        fn guestWorkValidationType() type {
            return struct {
                self: *Self,
                task_id: state.TaskId,
                item: state.WorkPublication,
                prior: ?state.WorkPublication,
                command: ?workspace.PublicationCommand,
                prefix: *const @import("../workspace_observers.zig").PublicationPrefix,
                a: std.mem.Allocator,
                work: workspace.Work,
                control: data.invocation.Control,
                quantum: u64,
                frozen_control: ?contracts.Decoded(data.invocation.Control),
                initial_checkpoint: ?[]const u8,
                fn run(ctx: *@This()) !void {
                    const advanced =
                        if (ctx.prior) |before|
                            ctx.item.execution_revision !=
                                before.execution_revision
                        else
                            true;
                    const pending = ctx.item.outer_operation != null or
                        if (ctx.item.guard) |guard| guard.pending_control != null else false;
                    if (!advanced and !pending) return;
                    var arena = std.heap.ArenaAllocator.init(ctx.self.allocator);
                    defer arena.deinit();
                    ctx.a = arena.allocator();
                    var observed = try contracts.decodeOwned(
                        workspace.WorkObservation,
                        ctx.a,
                        try store(ctx.self).acquiredObject(ctx.a, ctx.item.observation, null),
                    );
                    defer observed.deinit();
                    ctx.work = observed.value.work;
                    if (!std.meta.eql(ctx.work.task, ctx.task_id) or
                        !try samePublication(
                            ctx.a,
                            ctx.item,
                            try workPublication(ctx.a, observed.value),
                        ))
                        return error.InvalidArchive;
                    try ctx.identity();
                    defer if (ctx.frozen_control) |*decoded| decoded.deinit();

                    if (ctx.prior) |before| try ctx.initialControl(before);
                    if (ctx.quantum > 256) return error.InvalidArchive;
                    const encoded_control =
                        try contracts.encodeOwned(data.invocation.Control, ctx.a, ctx.control);
                    if (ctx.work.outer_operation) |operation_value| {
                        const retained =
                            try store(ctx.self).object(ctx.a, operation_value.control, null);
                        if (operation_value.guest_quantum != ctx.quantum or
                            !same(retained, encoded_control))
                            return error.InvalidArchive;
                    }
                    if (ctx.work.guard) |guard| if (guard.pending_control) |ref| {
                        const retained = try store(ctx.self).object(ctx.a, ref, null);
                        if (guard.guest_quantum != ctx.quantum or !same(retained, encoded_control))
                            return error.InvalidArchive;
                    };
                    if (!advanced) return;
                    try ctx.validateExecution(encoded_control);
                }

                fn identity(ctx: *@This()) !void {
                    var current =
                        try workspaceWork(ctx.self, ctx.a, ctx.task_id, ctx.item.work);
                    defer current.deinit();
                    inline for (.{
                        "program",
                        "input",
                        "input_value",
                        "origin_work",
                        "delegation",
                        "trial",
                    }) |field|
                        if (!std.meta.eql(@field(ctx.work, field), @field(current.value, field)))
                            return error.InvalidArchive;
                }

                fn initialControl(ctx: *@This(), before: state.WorkPublication) !void {
                    ctx.initial_checkpoint = try store(ctx.self).object(
                        ctx.a,
                        before.checkpoint orelse return error.InvalidArchive,
                        null,
                    );
                    ctx.quantum = ctx.prefix.guestQuantum(ctx.item.work);
                    var initial = try contracts.decodeOwned(
                        workspace.WorkObservation,
                        ctx.a,
                        try store(ctx.self).acquiredObject(ctx.a, before.observation, null),
                    );
                    defer initial.deinit();
                    if (!try samePublication(
                        ctx.a,
                        before,
                        try workPublication(ctx.a, initial.value),
                    ))
                        return error.InvalidArchive;
                    const cancellation = ctx.item.control.cancellation;
                    const cancel_requested = if (ctx.command) |selected|
                        selected == .control and selected.control.command == .cancel
                    else
                        false;
                    if (before.control.delivery == .settled_reply) {
                        try validateHistoricalOccurrence(ctx.self, ctx.a, initial.value);
                        const acquired = initial.value.occurrence orelse
                            return error.InvalidArchive;
                        const reply = switch (acquired.state) {
                            .settled_reply => |value| value.reply,
                            .admitted => |value| if (value ==
                                .reply) value.reply.reply else return error.InvalidArchive,
                            else => return error.InvalidArchive,
                        };
                        ctx.control = .{
                            .reply = try store(ctx.self).acquiredObject(ctx.a, reply, null),
                        };
                        if (cancellation != null and !before.control.cancellation_applied) {
                            ctx.quantum = 0;
                        }
                    } else if (cancellation != null and
                        (!before.control.cancellation_applied or cancel_requested))
                    {
                        ctx.control = .{ .cancel = .{ .text = cancellation.?.bytes } };
                    } else if (before.control.outcome == .yielded) ctx.control = .resume_yield;
                    if (initial.value.work.outer_operation) |operation_value| {
                        ctx.quantum = operation_value.guest_quantum;
                        ctx.frozen_control = try contracts.decodeOwned(
                            data.invocation.Control,
                            ctx.a,
                            try store(ctx.self).object(ctx.a, operation_value.control, null),
                        );
                        ctx.control = ctx.frozen_control.?.value;
                    } else if (cancellation == null)
                        if (before.guard) |guard|
                            if (guard.pending_control) |ref| {
                                ctx.frozen_control = try contracts.decodeOwned(
                                    data.invocation.Control,
                                    ctx.a,
                                    try store(ctx.self).object(ctx.a, ref, null),
                                );
                                ctx.control = ctx.frozen_control.?.value;
                                ctx.quantum = guard.guest_quantum;
                            };
                }

                fn replay(ctx: *@This(), prepared: *kosmos.Prepared, fact_key: state.Digest) !void {
                    var execution = if (ctx.initial_checkpoint) |checkpoint|
                        try kosmos.Session.restore(ctx.self.allocator, prepared, checkpoint)
                    else
                        try kosmos.Session.start(
                            ctx.self.allocator,
                            prepared,
                            try store(ctx.self).object(ctx.a, ctx.work.input, null),
                        );
                    defer execution.deinit();
                    _ = try kosmos.invocation.advance(&execution, ctx.control, ctx.quantum);
                    if (execution.transitions != ctx.item.guest_work) return error.InvalidArchive;
                    var finished =
                        try kosmos.invocation.finishPublication(ctx.a, &execution, .receipt, null);
                    defer finished.outcome.deinit();
                    defer ctx.self.allocator.free(finished.checkpoint.?);
                    const outcome = try data.invocation.encodeOwned(
                        data.invocation.Outcome,
                        ctx.a,
                        finished.outcome.record,
                    );
                    const expected_checkpoint = ctx.item.checkpoint orelse
                        return error.InvalidArchive;
                    if (!std.meta.eql(
                        storage.digest(finished.checkpoint.?),
                        expected_checkpoint.digest,
                    ) or
                        finished.checkpoint.?.len != expected_checkpoint.bytes or
                        !std.meta.eql(storage.digest(outcome), ctx.work.outcome.digest) or
                        outcome.len != ctx.work.outcome.bytes)
                        return error.InvalidArchive;
                    guest_segment_proofs.retain(fact_key);
                }

                fn validateExecution(ctx: *@This(), encoded_control: []const u8) !void {
                    var program =
                        try workspaceProgram(ctx.self, ctx.a, ctx.task_id, ctx.work.program);
                    defer program.deinit();
                    var packaged = try ctx.self.program.retainRuntime();
                    defer packaged.deinit();
                    const input_reference = if (ctx.prior) |before|
                        before.checkpoint.?
                    else
                        ctx.work.input;
                    const segment_fact = try guestSegmentFact(.{
                        .input = .{
                            .digest = input_reference.digest,
                            .bytes = input_reference.bytes,
                        },
                        .image = .{
                            .digest = program.value.description.image.digest,
                            .bytes = program.value.description.image.bytes,
                        },
                        .runtime = if (ctx.work.runtime) |runtime|
                            runtime.digest
                        else
                            packaged.identity,
                        .initial = ctx.prior == null,
                        .control = storage.digest(encoded_control),
                        .quantum = ctx.quantum,
                    }, ctx.work);
                    var prepared =
                        try inspectionRuntime(ctx.self, ctx.self.allocator, ctx.work);
                    defer prepared.deinit();
                    const fact_key = try guestSegmentKey(segment_fact);
                    if (try validatedGuestSegment(
                        ctx.self,
                        fact_key,
                        segment_fact,
                        ctx.work.outcome,
                    )) return;
                    try ctx.replay(&prepared, fact_key);
                }
            };
        }
        pub fn guestSegmentFact(
            segment: evaluator.Driver.Segment,
            work: workspace.Work,
        ) !CompilerFact {
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            var writer: data.wire.Writer = .{ .hasher = &hash };
            try data.record.write(struct {
                execution: evaluator.Driver.Segment,
                guest_work: u64,
                outcome: state.Reference,
            }, .{
                .execution = segment,
                .guest_work = work.guest_work,
                .outcome = work.outcome,
            }, &writer);
            return .{
                .kind = .guest_segment,
                .input = .{ .digest = segment.input.digest, .bytes = segment.input.bytes },
                .output = work.checkpoint,
                .context = hash.finalResult(),
            };
        }
        pub fn guestSegmentKey(fact: CompilerFact) !state.Digest {
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            var writer: data.wire.Writer = .{ .hasher = &hash };
            try data.record.write(CompilerFact, fact, &writer);
            return hash.finalResult();
        }
        fn validatedGuestSegment(
            self: *Self,
            key: state.Digest,
            fact: CompilerFact,
            outcome: state.Reference,
        ) !bool {
            if (!guest_segment_proofs.contains(key)) return false;
            try store(self).objectRange(fact.input, 0, &.{});
            try store(self).objectRange(fact.output, 0, &.{});
            try store(self).objectRange(outcome, 0, &.{});
            return true;
        }
    };
}
