const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const kosmos = @import("kosmos");
const workspace = @import("../workspace_state.zig");
const instrument = @import("../workspace_instrument.zig");
const wp = @import("../workspace_projection.zig");
const task_types = @import("types.zig");
const WorkspaceAdmission = task_types.WorkspaceAdmission;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const delegatedControl = Access.delegatedControl;
        const guardProgress = Guards.guardProgress;
        const guardSchedule = Guards.guardSchedule;
        const observationBlockedAt = Observers.observationBlockedAt;
        const publicationSchedule = Access.publicationSchedule;
        const store = Lifecycle.store;
        const trialControlReady = Execution.trialControlReady;
        const validateGuardProgress = Guards.validateGuardProgress;
        const validateGuardSelection = Guards.validateGuardSelection;
        const validateObserverPreparationProgress = Observers.validateObserverPreparationProgress;
        const validateObserverPublication = Observers.validateObserverPublication;
        const validateObserverSuccessionPublication =
            Observers.validateObserverSuccessionPublication;
        const validateRuntimeSwitch = Realization.validateRuntimeSwitch;
        const validateWorkspaceGuestWork = GuestValidation.validateWorkspaceGuestWork;
        const workspaceRuntime = Programs.workspaceRuntime;
        const workspaceStoppedAt = Access.workspaceStoppedAt;
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Execution = @import("workspace_execution.zig").Operations(Types, Self);
        const Guards = @import("workspace_guards.zig").Operations(Types, Self);
        const GuestValidation = @import("workspace_guest_validation.zig").Operations(Types, Self);
        const Observers = @import("workspace_observers.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Realization = @import("workspace_realization.zig").Operations(Types, Self);
        pub fn validateWorkspaceControl(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            event_value: state.Event,
            item: state.WorkPublication,
            prior: ?state.WorkPublication,
            command: ?workspace.PublicationCommand,
            admission: ?WorkspaceAdmission,
            outer_observed: bool,
            prefix: *@import("../workspace_observers.zig").PublicationPrefix,
            histories: *Observers.ObserverHistories,
        ) !void {
            var validation = WorkspaceControlValidation{
                .self = self,
                .a = a,
                .parent = parent,
                .event_value = event_value,
                .item = item,
                .prior = prior,
                .command = command,
                .admission = admission,
                .outer_observed = outer_observed,
                .prefix = prefix,
                .histories = histories,
                .actual = item.control,
                .expected = item.control,
                .execution_changed = false,
                .guarded_progress = false,
                .observer_progress = false,
            };
            return validation.run();
        }
        const WorkspaceControlValidation = workspaceControlValidationType();
        fn workspaceControlValidationType() type {
            return struct {
                self: *Self,
                a: std.mem.Allocator,
                parent: state.Task,
                event_value: state.Event,
                item: state.WorkPublication,
                prior: ?state.WorkPublication,
                command: ?workspace.PublicationCommand,
                admission: ?WorkspaceAdmission,
                outer_observed: bool,
                prefix: *@import("../workspace_observers.zig").PublicationPrefix,
                histories: *Observers.ObserverHistories,
                actual: workspace.ControlObservation,
                expected: workspace.ControlObservation,
                execution_changed: bool,
                guarded_progress: bool,
                observer_progress: bool,
                fn run(ctx: *@This()) !void {
                    if (try validateObserverSuccessionPublication(
                        ctx.self,
                        ctx.a,
                        ctx.event_value,
                        ctx.item,
                        ctx.prior,
                        ctx.command,
                    )) return;

                    ctx.execution_changed =
                        if (ctx.prior) |before|
                            ctx.item.execution_revision !=
                                before.execution_revision
                        else
                            true;
                    try ctx.runtimeProgress();
                    try ctx.outerProgress();
                    if ((ctx.actual.outcome == .requested) != (ctx.actual.delivery != null) or
                        (ctx.actual.port and ctx.actual.delivery == null))
                        return error.InvalidArchive;

                    try ctx.expectedInitial();
                    try validateGuardProgress(ctx.item, ctx.prior, ctx.command);
                    ctx.guarded_progress = if (ctx.prior) |before|
                        guardProgress(ctx.item, before)
                    else
                        false;
                    try validateObserverPublication(ctx.a, ctx.item, ctx.prior, ctx.command);
                    ctx.observer_progress = try validateObserverPreparationProgress(
                        ctx.self,
                        ctx.a,
                        ctx.parent.id,
                        ctx.event_value.seq,
                        ctx.item,
                        ctx.prior,
                        ctx.command,
                        ctx.histories,
                    );
                    if (ctx.command) |decoded| try ctx.selectedCommand(
                        decoded,
                    ) else try ctx.spontaneous();

                    try ctx.equalObservation();
                    try validateWorkspaceGuestWork(
                        ctx.self,
                        ctx.parent.id,
                        ctx.item,
                        ctx.prior,
                        ctx.command,
                        ctx.prefix,
                    );
                }

                fn runtimeProgress(ctx: *@This()) !void {
                    if (!ctx.execution_changed and ctx.item.guest_work != ctx.prior.?.guest_work)
                        return error.InvalidArchive;
                    if (ctx.execution_changed) {
                        var required = false;
                        if (ctx.item.runtime) |runtime| {
                            var selected = try workspaceRuntime(
                                ctx.self,
                                ctx.a,
                                ctx.parent.id,
                                runtime.digest,
                                null,
                            );
                            defer selected.deinit();
                            required = selected.admitted.content.value.hooks.enabled();
                        }
                        if (ctx.item.runtime_trace != required) return error.InvalidArchive;
                    } else if (ctx.command != null and ctx.command.? == .realize) {
                        if (ctx.item.runtime_trace) return error.InvalidArchive;
                    } else if (ctx.item.runtime_trace != ctx.prior.?.runtime_trace)
                        return error.InvalidArchive;
                }

                fn outerProgress(ctx: *@This()) !void {
                    if (ctx.execution_changed and ctx.item.outer_operation != null)
                        return error.InvalidArchive;
                    if (ctx.item.outer_operation) |current_capsule| {
                        if (ctx.prior) |before| {
                            if (before.outer_operation) |previous_capsule| {
                                if (!std.meta.eql(current_capsule, previous_capsule)) {
                                    const before_bytes =
                                        try store(ctx.self).object(ctx.a, previous_capsule, null);
                                    defer ctx.a.free(before_bytes);
                                    const after_bytes =
                                        try store(ctx.self).object(ctx.a, current_capsule, null);
                                    defer ctx.a.free(after_bytes);
                                    var previous =
                                        try kosmos.RuntimeCapsule.read(ctx.a, before_bytes);
                                    defer previous.deinit();
                                    var current =
                                        try kosmos.RuntimeCapsule.read(ctx.a, after_bytes);
                                    defer current.deinit();
                                    if (current.value.record.outer_revision <=
                                        previous.value.record.outer_revision or
                                        current.value.record.guest_revision !=
                                            previous.value.record.guest_revision or
                                        !std.meta.eql(
                                            current.value.record.artifact,
                                            previous.value.record.artifact,
                                        ) or
                                        !same(current.value.command, previous.value.command))
                                        return error.InvalidArchive;
                                }
                            } else if (ctx.command == null or ctx.command.? != .pump)
                                return error.InvalidArchive;
                        } else return error.InvalidArchive;
                    } else if (!ctx.execution_changed and ctx.prior != null and
                        ctx.prior.?.outer_operation != null)
                        return error.InvalidArchive;
                }

                fn expectedInitial(ctx: *@This()) !void {
                    if (ctx.prior) |before| {
                        if (ctx.command == null or ctx.command.? != .realize) {
                            if (!std.meta.eql(ctx.item.runtime, before.runtime) or
                                ctx.item.realization_revision != before.realization_revision)
                                return error.InvalidArchive;
                        }
                        if (ctx.item.execution_revision == before.execution_revision) {
                            if (!std.meta.eql(ctx.item.checkpoint, before.checkpoint))
                                return error.InvalidArchive;
                            const pumping = ctx.item.outer_operation != null and
                                !std.meta.eql(ctx.item.outer_operation, before.outer_operation);
                            if (!pumping and (ctx.command == null or (ctx.command.? != .realize and
                                ctx.command.? != .request_cut)))
                                if (!std.meta.eql(ctx.item.runtime_capsule, before.runtime_capsule))
                                    return error.InvalidArchive;
                        } else if (ctx.item.runtime_capsule != null and !ctx.outer_observed)
                            return error.InvalidArchive;
                        ctx.expected.policy = before.control.policy;
                        ctx.expected.cancellation = before.control.cancellation;
                        ctx.expected.blocker = before.control.blocker;
                        if (ctx.execution_changed and ctx.expected.blocker == .observation_blocked)
                            ctx.expected.blocker = null;
                        ctx.expected.schedule = before.control.schedule;
                        if (ctx.actual.instrument != before.control.instrument or
                            ctx.actual.trial != before.control.trial)
                            return error.InvalidArchive;
                        if (ctx.item.execution_revision == before.execution_revision and
                            (ctx.actual.outcome != before.control.outcome or
                                ctx.actual.port != before.control.port or
                                ctx.actual.cancellation_applied !=
                                    before.control.cancellation_applied))
                            return error.InvalidArchive;
                    } else {
                        if (ctx.item.execution_revision != 1 or ctx.item.control_revision != 1 or
                            ctx.command == null)
                            return error.InvalidArchive;
                        if (ctx.item.realization_revision != 0 or ctx.item.runtime_capsule != null)
                            return error.InvalidArchive;
                        ctx.expected.cancellation = null;
                        ctx.expected.blocker = null;
                        if (ctx.actual.cancellation_applied) return error.InvalidArchive;
                    }
                }

                fn commandDelegate(
                    ctx: *@This(),
                    selection: @FieldType(workspace.PublicationCommand, "delegate"),
                ) !void {
                    if (selection.interpretation == .none) return error.InvalidArchive;
                    const target = try wp.identity(selection.expected.work, .work);
                    if (std.meta.eql(ctx.item.work, target)) {
                        const before = ctx.prior orelse return error.InvalidArchive;
                        if (selection.expected.execution_revision != before.execution_revision or
                            selection.expected.control_revision != before.control_revision or
                            ctx.item.execution_revision != before.execution_revision or
                            ctx.item.control_revision -| before.control_revision != 1 or
                            ctx.actual.delivery != before.control.delivery)
                            return error.InvalidArchive;
                        ctx.expected.policy = selection.policy;
                        ctx.expected.schedule = .parked;
                    } else {
                        if (ctx.prior != null or !ctx.actual.instrument or !std.meta.eql(
                            (ctx.admission orelse return error.InvalidArchive).work,
                            ctx.item.work,
                        )) return error.InvalidArchive;
                        if (ctx.item.runtime != null) return error.InvalidArchive;
                        ctx.expected.policy = .{
                            .stop = .terminal,
                            .continuation = .owner_scheduled,
                        };
                        ctx.expected.schedule = publicationSchedule(ctx.expected);
                    }
                }

                fn commandInteract(
                    ctx: *@This(),
                    interaction: @FieldType(workspace.PublicationCommand, "interact"),
                ) !void {
                    const before = ctx.prior orelse return error.InvalidArchive;
                    if (!std.meta.eql(
                        try wp.identity(interaction.expected.work, .work),
                        ctx.item.work,
                    ) or
                        interaction.expected.execution_revision != before.execution_revision or
                        interaction.expected.control_revision != before.control_revision or
                        ctx.item.execution_revision != before.execution_revision or
                        ctx.item.control_revision -| before.control_revision != 1 or
                        ctx.actual.delivery != .settled_reply) return error.InvalidArchive;
                    ctx.expected.schedule = .queued;
                }

                fn commandControl(
                    ctx: *@This(),
                    control: @FieldType(workspace.PublicationCommand, "control"),
                ) !void {
                    const before = ctx.prior orelse return error.InvalidArchive;
                    if (control.execution != before.execution_revision or
                        control.control != before.control_revision)
                        return error.InvalidArchive;
                    if (before.control.outcome == .completed or before.control.outcome == .failed or
                        before.control.outcome == .cancelled)
                        return error.InvalidArchive;
                    const advanced = ctx.item.execution_revision > before.execution_revision;
                    if (control.command == .advance) {
                        try ctx.advanceControl(before, advanced);
                    } else {
                        if (ctx.item.control_revision -| before.control_revision != 1)
                            return error.InvalidArchive;
                        try ctx.changeControl(before, advanced, control);
                    }
                }

                fn commandStart(
                    ctx: *@This(),
                    start: @FieldType(workspace.PublicationCommand, "start"),
                ) !void {
                    if (ctx.prior != null or ctx.actual.instrument) return error.InvalidArchive;
                    if (!std.meta.eql(ctx.item.runtime, start.runtime)) return error.InvalidArchive;
                    ctx.expected.policy = start.policy;
                    ctx.expected.schedule = publicationSchedule(ctx.expected);
                }

                fn commandRequestCut(
                    ctx: *@This(),
                    selection: @FieldType(workspace.PublicationCommand, "request_cut"),
                ) !void {
                    const before = ctx.prior orelse return error.InvalidArchive;
                    if (selection.expected.execution_revision != before.execution_revision or
                        selection.expected.control_revision != before.control_revision or
                        !std.meta.eql(
                            try wp.identity(selection.expected.work, .work),
                            ctx.item.work,
                        ) or
                        ctx.item.execution_revision != before.execution_revision or
                        ctx.item.control_revision -| before.control_revision != 1 or
                        ctx.actual.delivery == .dispatching or
                        ctx.actual.delivery == .unknown or
                        ctx.actual.delivery != before.control.delivery or
                        ctx.item.runtime_capsule == null)
                        return error.InvalidArchive;
                    const capsule_bytes =
                        try store(ctx.self).object(ctx.a, ctx.item.runtime_capsule.?, null);
                    defer ctx.a.free(capsule_bytes);
                    var capsule = try kosmos.RuntimeCapsule.read(ctx.a, capsule_bytes);
                    defer capsule.deinit();
                    if (!same(@tagName(capsule.value.record.kind), @tagName(selection.level)))
                        return error.InvalidArchive;
                }

                fn commandPump(
                    ctx: *@This(),
                    selection: @FieldType(workspace.PublicationCommand, "pump"),
                ) !void {
                    const before = ctx.prior orelse return error.InvalidArchive;
                    if (selection.expected.execution_revision != before.execution_revision or
                        selection.expected.control_revision != before.control_revision or
                        !std.meta.eql(
                            try wp.identity(selection.expected.work, .work),
                            ctx.item.work,
                        ) or ctx.item.control_revision -| before.control_revision != 1 or
                        selection.base_quantum == 0 or
                        selection.base_quantum > 1048576)
                        return error.InvalidArchive;
                    if (ctx.execution_changed) {
                        ctx.expected.schedule = publicationSchedule(ctx.expected);
                    } else if (ctx.guarded_progress) {
                        if (ctx.actual.delivery != before.control.delivery)
                            return error.InvalidArchive;
                        ctx.expected.schedule =
                            guardSchedule(ctx.item.guard.?, ctx.expected.policy);
                    } else if (before.outer_operation == null and
                        trialControlReady(before.control))
                    {
                        if (ctx.item.outer_operation != null or ctx.actual.delivery != .ready)
                            return error.InvalidArchive;
                        ctx.expected.delivery = .ready;
                        ctx.expected.schedule = .queued;
                        ctx.expected.blocker = null;
                    } else {
                        if (ctx.item.outer_operation == null or
                            ctx.actual.delivery != before.control.delivery)
                            return error.InvalidArchive;
                        ctx.expected.schedule = if (ctx.expected.cancellation != null or
                            ctx.expected.policy.continuation == .owner_scheduled)
                            .queued
                        else
                            .parked;
                    }
                }

                fn commandRealize(
                    ctx: *@This(),
                    selection: @FieldType(workspace.PublicationCommand, "realize"),
                ) !void {
                    const before = ctx.prior orelse return error.InvalidArchive;
                    if (before.outer_operation != null or
                        selection.execution != before.execution_revision or
                        selection.control != before.control_revision or
                        selection.realization != before.realization_revision or
                        ctx.item.execution_revision != before.execution_revision or
                        ctx.item.control_revision -| before.control_revision != 1 or
                        ctx.item.realization_revision -| before.realization_revision != 1 or
                        !std.meta.eql(ctx.item.runtime, selection.runtime) or
                        !std.meta.eql(ctx.item.runtime_capsule, selection.target) or
                        ctx.actual.delivery == .dispatching or
                        ctx.actual.delivery == .unknown or
                        ctx.actual.delivery != before.control.delivery)
                        return error.InvalidArchive;
                    try validateRuntimeSwitch(
                        ctx.self,
                        ctx.a,
                        ctx.parent.id,
                        ctx.item,
                        before,
                        selection,
                    );
                }

                fn commandGuard(ctx: *@This(), decoded: workspace.PublicationCommand) !void {
                    const before = ctx.prior orelse return error.InvalidArchive;
                    try validateGuardSelection(ctx.item, before, decoded);
                }

                fn spontaneous(ctx: *@This()) !void {
                    const before = ctx.prior orelse return error.InvalidArchive;
                    if (ctx.item.execution_revision > before.execution_revision) {
                        if (ctx.item.control_revision != before.control_revision)
                            return error.InvalidArchive;
                        ctx.expected.schedule = publicationSchedule(ctx.expected);
                    } else if (ctx.guarded_progress) {
                        if (ctx.item.control_revision != before.control_revision or
                            ctx.actual.delivery != before.control.delivery)
                            return error.InvalidArchive;
                        ctx.expected.schedule =
                            guardSchedule(ctx.item.guard.?, ctx.expected.policy);
                    } else if (ctx.item.outer_operation != null and
                        before.outer_operation != null and
                        ctx.item.control_revision == before.control_revision)
                    {
                        if (ctx.actual.delivery != before.control.delivery)
                            return error.InvalidArchive;
                        ctx.expected.schedule = if (ctx.expected.cancellation != null or
                            ctx.expected.policy.continuation == .owner_scheduled)
                            .queued
                        else
                            .parked;
                    } else if (ctx.observer_progress) {
                        if (ctx.item.control_revision != before.control_revision or
                            ctx.actual.delivery != before.control.delivery)
                            return error.InvalidArchive;
                    } else if (ctx.item.control_revision > before.control_revision) {
                        if (ctx.item.execution_revision != before.execution_revision or
                            !try workspaceStoppedAt(
                                ctx.self,
                                ctx.a,
                                ctx.parent.id,
                                ctx.event_value.seq - 1,
                            ) or ctx.actual.delivery !=
                            before.control.delivery) return error.InvalidArchive;
                        ctx.expected.schedule = .parked;
                    } else {
                        try ctx.deliveryProgress(before);
                    }
                }

                fn selectedCommand(ctx: *@This(), decoded: workspace.PublicationCommand) !void {
                    switch (decoded) {
                        .stop_observing => {},
                        .build,
                        .retain,
                        .import,
                        .context,
                        .specialize,
                        .semantic,
                        .residual,
                        .realize_controller,
                        => return error.InvalidArchive,
                        .guard, .unguard => try ctx.commandGuard(decoded),
                        .realize => |selection| try ctx.commandRealize(selection),
                        .pump => |selection| try ctx.commandPump(selection),
                        .request_cut => |selection| try ctx.commandRequestCut(selection),
                        .start => |start| try ctx.commandStart(start),
                        .control => |control| try ctx.commandControl(control),
                        .interact => |interaction| try ctx.commandInteract(interaction),
                        .delegate => |selection| try ctx.commandDelegate(selection),
                    }
                }

                fn equalObservation(ctx: *@This()) !void {
                    const expected_bytes = try contracts.encodeOwned(
                        workspace.ControlObservation,
                        ctx.a,
                        ctx.expected,
                    );
                    defer ctx.a.free(expected_bytes);
                    const actual_bytes =
                        try contracts.encodeOwned(workspace.ControlObservation, ctx.a, ctx.actual);
                    defer ctx.a.free(actual_bytes);
                    if (!same(expected_bytes, actual_bytes)) return error.InvalidArchive;
                }
                fn advanceControl(
                    ctx: *@This(),
                    before: state.WorkPublication,
                    advanced: bool,
                ) !void {
                    if (!advanced and ctx.guarded_progress) {
                        if (ctx.item.control_revision != before.control_revision or
                            ctx.actual.delivery != before.control.delivery)
                            return error.InvalidArchive;
                        ctx.expected.schedule =
                            guardSchedule(ctx.item.guard.?, ctx.expected.policy);
                    } else if (!advanced and before.outer_operation == null and
                        trialControlReady(before.control))
                    {
                        if (ctx.item.control_revision -| before.control_revision != 1 or
                            ctx.item.outer_operation != null or ctx.actual.delivery != .ready)
                            return error.InvalidArchive;
                        ctx.expected.delivery = .ready;
                        ctx.expected.schedule = .queued;
                        ctx.expected.blocker = null;
                    } else if (advanced) {
                        if (ctx.item.control_revision != before.control_revision)
                            return error.InvalidArchive;
                        ctx.expected.schedule = publicationSchedule(ctx.expected);
                    } else {
                        if (ctx.item.control_revision != before.control_revision or
                            before.outer_operation == null or
                            ctx.item.outer_operation == null or
                            ctx.actual.delivery != before.control.delivery)
                            return error.InvalidArchive;
                        ctx.expected.schedule = if (ctx.expected.cancellation != null or
                            ctx.expected.policy.continuation ==
                                .owner_scheduled) .queued else .parked;
                    }
                }
                fn changeControl(
                    ctx: *@This(),
                    before: state.WorkPublication,
                    advanced: bool,
                    control: @FieldType(workspace.PublicationCommand, "control"),
                ) !void {
                    switch (control.command) {
                        .park => {
                            if (advanced or ctx.actual.delivery != before.control.delivery)
                                return error.InvalidArchive;
                            ctx.expected.schedule = .parked;
                        },
                        .delegate => |policy| {
                            if (advanced) return error.InvalidArchive;
                            const delegated = delegatedControl(
                                before.control,
                                before.outer_operation != null,
                                before.guard,
                                policy,
                            );
                            ctx.expected.policy = delegated.policy;
                            ctx.expected.delivery = delegated.delivery;
                            ctx.expected.schedule = delegated.schedule;
                        },
                        .cancel => |reason| {
                            if (ctx.expected.cancellation == null)
                                ctx.expected.cancellation = reason;
                            if (advanced) {
                                ctx.expected.schedule = publicationSchedule(ctx.expected);
                            } else if (ctx.actual.blocker == .observation_blocked) {
                                if (ctx.actual.delivery != before.control.delivery or
                                    !std.meta.eql(ctx.item.outer_operation, before.outer_operation))
                                    return error.InvalidArchive;
                                if (!try observationBlockedAt(before, ctx.prefix))
                                    return error.InvalidArchive;
                                ctx.expected.schedule = .queued;
                                ctx.expected.blocker = .observation_blocked;
                            } else {
                                if (ctx.actual.delivery != before.control.delivery)
                                    return error.InvalidArchive;
                                ctx.expected.schedule =
                                    if (ctx.item.outer_operation !=
                                    null) .queued else switch (ctx.actual.delivery orelse
                                    return error.InvalidArchive) {
                                        .dispatching => .active,
                                        .captured => .queued,
                                        .unknown => .parked,
                                        else => return error.InvalidArchive,
                                    };
                            }
                        },
                        .advance => unreachable,
                    }
                }
                fn deliveryProgress(ctx: *@This(), before: state.WorkPublication) !void {
                    if (ctx.item.execution_revision != before.execution_revision or
                        ctx.item.control_revision != before.control_revision or
                        ctx.actual.delivery == null)
                        return error.InvalidArchive;
                    if (ctx.actual.delivery == .settled_reply and
                        before.control.delivery == .settled_reply and
                        before.control.trial and
                        before.control.policy.continuation == .explicit_only and
                        before.control.cancellation == null)
                    {
                        ctx.expected.schedule = .parked;
                    } else if (ctx.actual.delivery == before.control.delivery and
                        ctx.actual.blocker != null)
                    {
                        // A dispatch/interpretation rejection records an actual
                        // environmental diagnostic, not an execution result.
                        if (ctx.actual.delivery != .ready and ctx.actual.delivery != .captured and
                            ctx.actual.delivery != .unknown)
                            return error.InvalidArchive;
                        ctx.expected.blocker = ctx.actual.blocker;
                        ctx.expected.schedule = .parked;
                    } else switch (ctx.actual.delivery.?) {
                        .dispatching => {
                            ctx.expected.schedule = .active;
                            ctx.expected.blocker = null;
                        },
                        .captured, .settled_reply => {
                            ctx.expected.schedule =
                                if (before.control.schedule == .parked) .parked else .queued;
                            ctx.expected.blocker = null;
                        },
                        .unknown => {
                            ctx.expected.schedule = .parked;
                            ctx.expected.blocker = .unavailable_environment;
                        },
                        .not_sent => {
                            const cancelling = ctx.actual.cancellation != null and
                                !ctx.actual.cancellation_applied;
                            ctx.expected.schedule = if (cancelling and
                                before.control.schedule != .parked) .queued else .parked;
                            ctx.expected.blocker =
                                if (cancelling) null else .unavailable_environment;
                        },
                        else => return error.InvalidArchive,
                    }
                }
            };
        }
    };
}
