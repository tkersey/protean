const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const registry = @import("../registry.zig");
const json = @import("../json.zig");
const values = @import("../values.zig");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const ControllerRuntimeCut = task_types.ControllerRuntimeCut;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const controllerBinding = Controller.controllerBinding;
        const controllerRuntimeAt = Realization.controllerRuntimeAt;
        const freezeWorkspaceWork = Access.freezeWorkspaceWork;
        const projectionBinding = Worker.projectionBinding;
        const renderWorkspaceWorkObservationIn = Observations.renderWorkspaceWorkObservationIn;
        const store = Lifecycle.store;
        const validateHistoricalOccurrence = Replay.validateHistoricalOccurrence;
        const validateWorkspaceWorkSnapshotIn = Snapshots.validateWorkspaceWorkSnapshotIn;
        const workspaceIds = Recovery.workspaceIds;
        const workspaceScopeAt = Access.workspaceScopeAt;
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Recovery = @import("work_recovery.zig").Operations(Types, Self);
        const Worker = @import("worker_execution.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Observations = @import("workspace_observations.zig").Operations(Types, Self);
        const Observers = @import("workspace_observers.zig").Operations(Types, Self);
        const Realization = @import("workspace_realization.zig").Operations(Types, Self);
        const Replay = @import("workspace_replay.zig").Operations(Types, Self);
        const ResidualValidation =
            @import("workspace_residual_validation.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        pub fn controllerInternal(identity: []const u8) bool {
            const c = contracts.controller;
            return same(identity, c.boot_identity) or
                same(identity, c.offer_identity) or
                same(identity, c.handoff_identity);
        }
        pub fn controllerOverlay(
            self: *Self,
            allocator: std.mem.Allocator,
            parent: state.Task,
            binding_id: state.Digest,
            handoff: state.Digest,
            event_cut: u64,
            next_message: u64,
            epoch: u64,
        ) ![]u8 {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const binding = try controllerBinding(self, a, parent, binding_id);
            const user = try controllerOverlayUser(self, a, parent, next_message, event_cut);
            const control = try controllerOverlayControl(
                self,
                a,
                parent,
                binding_id,
                binding.program,
                handoff,
                event_cut,
                epoch,
            );
            var overlay = json.object();
            try json.put(a, &overlay, "user", user);
            try json.put(a, &overlay, "control", control);
            return json.canonical(allocator, overlay);
        }
        fn controllerOverlayUser(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            next_message: u64,
            event_cut: u64,
        ) !json.Value {
            var input = try contracts.decodeOwned(
                Types.Input,
                a,
                try store(self).object(a, parent.input, null),
            );
            defer input.deinit();
            var user = json.object();
            try json.put(a, &user, "task", try values.toJson(Types.Input, a, input.value));
            try json.put(
                a,
                &user,
                "amendments_in_admission_order",
                try controllerOverlayAmendments(self, a, parent.id, next_message),
            );
            try json.put(
                a,
                &user,
                "admitted_human_answers",
                try controllerOverlayAnswers(self, a, parent.id, event_cut),
            );
            return user;
        }
        fn controllerOverlayAmendments(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            next_message: u64,
        ) !json.Value {
            const Amendment = struct { ordinal: u64, value: json.Value };
            var amendments: std.ArrayList(Amendment) = .empty;
            var rows = try store(self).database.prepare(
                "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body W" ++
                    "HERE r.task=? AND r.kind='message'",
                &.{.{ .blob = &task_id }},
            );
            defer rows.deinit();
            while (try rows.step() == .row) {
                var saved = try contracts.decodeOwned(state.Message, a, try rows.bytes(0));
                defer saved.deinit();
                if (saved.value.ordinal >= next_message) continue;
                var amendment = try contracts.decodeOwned(
                    Types.Message,
                    a,
                    try store(self).object(a, saved.value.value, null),
                );
                defer amendment.deinit();
                try amendments.append(a, .{
                    .ordinal = saved.value.ordinal,
                    .value = try values.toJson(Types.Message, a, amendment.value),
                });
            }
            std.mem.sort(Amendment, amendments.items, {}, struct {
                fn less(_: void, left: Amendment, right: Amendment) bool {
                    return left.ordinal < right.ordinal;
                }
            }.less);
            if (next_message == 0 or amendments.items.len != next_message - 1)
                return error.CorruptState;
            var messages: json.Value = .{ .array = .init(a) };
            for (amendments.items, 1..) |item, ordinal| {
                if (item.ordinal != ordinal) return error.CorruptState;
                try messages.array.append(item.value);
            }
            return messages;
        }
        fn controllerOverlayAnswers(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            event_cut: u64,
        ) !json.Value {
            var answers: json.Value = .{ .array = .init(a) };
            var questions = try store(self).database.prepare(
                "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body W" ++
                    "HERE r.task=? AND r.kind='question' ORDER BY r.id",
                &.{.{ .blob = &task_id }},
            );
            defer questions.deinit();
            while (try questions.step() == .row) {
                var question = try contracts.decodeOwned(state.Question, a, try questions.bytes(0));
                defer question.deinit();
                const answer = question.value.answer orelse continue;
                const answer_receipt = question.value.receipt orelse return error.CorruptState;
                var admitted = try store(self).database.prepare(
                    "SELECT 1 FROM events WHERE task=? AND revision=? AND seq<=?",
                    &.{ .{ .blob = &task_id }, .{
                        .integer = std.math.cast(i64, answer_receipt.revision) orelse
                            return error.CorruptState,
                    }, .{
                        .integer = std.math.cast(i64, event_cut) orelse return error.CorruptState,
                    } },
                );
                defer admitted.deinit();
                if (try admitted.step() != .row) continue;
                const Answer = if (@hasDecl(Types, "Answer")) Types.Answer else void;
                var decoded =
                    try contracts.decodeOwned(Answer, a, try store(self).object(a, answer, null));
                defer decoded.deinit();
                var observed = json.object();
                try json.put(
                    a,
                    &observed,
                    "question",
                    json.string(try a.dupe(u8, &std.fmt.bytesToHex(question.value.id, .lower))),
                );
                try json.put(
                    a,
                    &observed,
                    "prompt",
                    json.string(try store(self).object(a, question.value.prompt, null)),
                );
                try json.put(a, &observed, "answer", try values.toJson(Answer, a, decoded.value));
                try answers.array.append(observed);
            }
            return answers;
        }
        fn controllerOverlayControl(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            binding_id: state.Digest,
            program_id: state.Digest,
            handoff: state.Digest,
            event_cut: u64,
            epoch: u64,
        ) !json.Value {
            var control = json.object();
            try json.put(
                a,
                &control,
                "task",
                json.string(try a.dupe(u8, &std.fmt.bytesToHex(parent.id, .lower))),
            );
            try json.put(a, &control, "controller_epoch", try json.number(a, epoch));
            try json.put(
                a,
                &control,
                "expected_handoff_identity",
                json.string(try a.dupe(u8, &std.fmt.bytesToHex(handoff, .lower))),
            );
            try json.put(
                a,
                &control,
                "realization_target",
                try controllerRealizationTarget(
                    self,
                    a,
                    parent,
                    binding_id,
                    handoff,
                    event_cut,
                    epoch,
                ),
            );

            try json.put(
                a,
                &control,
                "program",
                try values.toJson(wc.Ref, a, try wp.reference(a, .program, program_id)),
            );
            try json.put(a, &control, "event_cut", try json.number(a, event_cut));
            try json.put(
                a,
                &control,
                "policy_identity",
                json.string(try a.dupe(u8, &std.fmt.bytesToHex(parent.profile.digest, .lower))),
            );
            try json.put(
                a,
                &control,
                "inspection",
                json.string(
                    "program.describe current_controller exposes exact source, carry " ++
                        "and contracts. context and work operations expose retained task " ++
                        "evidence. Program construction and adoption require their existi" ++
                        "ng task permissions.",
                ),
            );
            return control;
        }
        fn controllerRealizationTarget(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            binding_id: state.Digest,
            handoff: state.Digest,
            event_cut: u64,
            epoch: u64,
        ) !json.Value {
            const runtime_cut: ControllerRuntimeCut = if (event_cut == parent.event_high and
                epoch == parent.controller_epoch and
                std.meta.eql(parent.controller, @as(?state.Digest, binding_id)))
                .{
                    .runtime = parent.controller_runtime,
                    .realization_revision = parent.realization_revision,
                }
            else if (parent.realization_revision != 0 or
                !std.meta.eql(parent.controller, @as(?state.Digest, binding_id)))
                try controllerRuntimeAt(self, a, parent, event_cut)
            else
                ControllerRuntimeCut{};
            return values.toJson(wc.ControllerRealizationTarget, a, .{ .action = .{
                .interaction = .{
                    .bytes = try a.dupe(u8, &std.fmt.bytesToHex(handoff, .lower)),
                },
                .epoch = epoch,
                .realization_revision = runtime_cut.realization_revision,
            } });
        }
        pub fn controllerSelection(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            response: []const u8,
        ) !?wc.Adoption {
            const entry = for (self.handlers.entries) |item| {
                if (item.declaration.controller_import == .deliberate) break item;
            } else return null;
            const callback = entry.declaration.controller_choice orelse return null;
            return store(self).project(?wc.Adoption, a, self.handlers, projectionBinding(
                self,
                parent,
            ), struct {
                callback: @TypeOf(callback),
                response: []const u8,
                pub fn run(this: @This(), context: registry.ProjectionContext) !?wc.Adoption {
                    return this.callback(context, this.response);
                }
            }{ .callback = callback, .response = response });
        }
        pub fn controllerPermission(self: *Self, a: std.mem.Allocator, parent: state.Task) !bool {
            const entry = for (self.handlers.entries) |item| {
                if (item.declaration.controller_import == .deliberate) break item;
            } else return false;
            const callback = entry.declaration.controller_permission orelse return false;
            return store(self).project(bool, a, self.handlers, projectionBinding(
                self,
                parent,
            ), struct {
                callback: @TypeOf(callback),
                pub fn run(this: @This(), context: registry.ProjectionContext) !bool {
                    return this.callback(context) catch |err| switch (err) {
                        error.ToolConstructionNotAdmitted => false,
                        else => return err,
                    };
                }
            }{ .callback = callback });
        }
        pub fn freeControllerViewWorks(
            a: std.mem.Allocator,
            snapshots: []const workspace.WorkObservation,
        ) void {
            for (snapshots) |snapshot| freeControllerViewWork(a, snapshot);
            a.free(snapshots);
        }
        fn freeControllerViewWork(a: std.mem.Allocator, snapshot: workspace.WorkObservation) void {
            const work = snapshot.work;
            a.free(work.inputs.items);
            a.free(work.runtime_dependencies.items);
            if (work.runtime_trace) |trace| a.free(trace.dependencies.items);
            if (work.outer_operation) |pending| a.free(pending.dependencies.items);
            if (work.guard) |guard| {
                if (guard.reference_operation) |pending| a.free(pending.dependencies.items);
                if (guard.failure) |failure| a.free(failure.bytes);
            }
            if (work.cancellation) |reason| a.free(reason.bytes);
            if (work.observer) |observer|
                @import("../workspace_observers.zig").freeObserver(a, observer);
        }
        pub fn controllerView(
            self: *Self,
            allocator: std.mem.Allocator,
            parent: state.Task,
        ) !struct {
            bytes: []u8,
            works: []workspace.WorkObservation,
        } {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const messages = try controllerViewMessages(self, a, parent);
            const ids = try workspaceIds(self, a, parent.id);
            const works = try a.alloc(contracts.controller.WorkFact, ids.len);
            const snapshots = try allocator.alloc(workspace.WorkObservation, ids.len);
            var initialized: usize = 0;
            errdefer {
                for (snapshots[0..initialized]) |snapshot| freeControllerViewWork(
                    allocator,
                    snapshot,
                );
                allocator.free(snapshots);
            }
            var observers = Observers.CurrentObservers.init(a, parent.id, parent.event_high);
            defer observers.deinit();
            for (ids, works, snapshots) |id, *out, *snapshot| {
                snapshot.* = try freezeWorkspaceWork(
                    self,
                    allocator,
                    parent.id,
                    try wp.reference(a, .work, id),
                    true,
                );
                initialized += 1;
                out.* = try controllerWorkFact(self, a, parent, id, snapshot.*, &observers);
            }
            return .{
                .works = snapshots,
                .bytes = try contracts.encodeOwned(
                    contracts.controller.OwnerView,
                    allocator,
                    .{
                        .task = parent.id,
                        .event_cut = parent.event_high,
                        .next_message = parent.next_message,
                        .policy = parent.profile.digest,
                        .input_schema = .{ .bytes = try values.schemaBytes(Types.Input, a) },
                        .input = .{ .bytes = try store(self).object(a, parent.input, null) },
                        .messages = .{ .items = messages },
                        .works = .{ .items = works },
                    },
                ),
            };
        }
        fn controllerWorkFact(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            id: state.Digest,
            snapshot: workspace.WorkObservation,
            observers: *Observers.CurrentObservers,
        ) !contracts.controller.WorkFact {
            const child = snapshot.work;
            return .{
                .work = try wp.reference(a, .work, id),
                .execution_revision = child.execution_revision,
                .control_revision = child.control_revision,
                .event_watermark = child.event_watermark,
                .observation = .{
                    .bytes = try json.canonical(
                        a,
                        try renderWorkspaceWorkObservationIn(
                            self,
                            a,
                            child,
                            snapshot.occurrence,
                            parent.event_high,
                            .{ .current = observers },
                        ),
                    ),
                },
            };
        }
        fn controllerViewMessages(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
        ) ![]contracts.Bytes(null) {
            const messages = try a.alloc(contracts.Bytes(null), @intCast(parent.next_message - 1));
            const found = try a.alloc(bool, messages.len);
            @memset(found, false);
            var rows = try store(self).database.prepare(
                "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body W" ++
                    "HERE r.task=? AND r.kind='message'",
                &.{.{ .blob = &parent.id }},
            );
            defer rows.deinit();
            while (try rows.step() == .row) {
                var saved = try contracts.decodeOwned(state.Message, a, try rows.bytes(0));
                defer saved.deinit();
                if (saved.value.ordinal == 0 or saved.value.ordinal >= parent.next_message)
                    return error.CorruptState;
                const i: usize = @intCast(saved.value.ordinal - 1);
                if (found[i]) return error.CorruptState;
                found[i] = true;
                messages[i] = .{ .bytes = try store(self).object(a, saved.value.value, null) };
            }
            for (found) |present| if (!present) return error.CorruptState;
            return messages;
        }
        pub fn validateControllerViewIn(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            view: contracts.controller.OwnerView,
            snapshots: []const workspace.WorkObservation,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) anyerror!void {
            if (!std.meta.eql(view.task, parent.id) or
                view.event_cut > parent.event_high or
                view.next_message == 0 or
                view.next_message > parent.next_message or
                !std.meta.eql(view.policy, parent.profile.digest) or !same(
                view.input.bytes,
                try store(self).object(a, parent.input, null),
            ) or !same(view.input_schema.bytes, try values.schemaBytes(Types.Input, a)))
                return error.InvalidArchive;
            try validateControllerViewMessages(self, a, parent, view);
            try validateControllerMessageCut(self, a, parent, view.event_cut, view.next_message);
            const ids = try workspaceScopeAt(self, a, parent.id, view.event_cut);
            if (ids.len != view.works.items.len or ids.len != snapshots.len)
                return error.InvalidArchive;
            for (ids, view.works.items, snapshots) |id, fact, snapshot| {
                const child = snapshot.work;
                if (!std.meta.eql(id, try wp.identity(fact.work, .work)) or
                    !std.meta.eql(id, child.id) or
                    fact.execution_revision != child.execution_revision or
                    fact.control_revision != child.control_revision or
                    fact.event_watermark != child.event_watermark or
                    child.event_watermark != try ResidualValidation.workspacePublicationAt(
                        self,
                        a,
                        parent.id,
                        id,
                        view.event_cut,
                    )) return error.InvalidArchive;
                try validateWorkspaceWorkSnapshotIn(self, parent, snapshot, records, checked);
                try validateHistoricalOccurrence(self, a, snapshot);
                if (!same(
                    fact.observation.bytes,
                    try json.canonical(
                        a,
                        try renderWorkspaceWorkObservationIn(
                            self,
                            a,
                            child,
                            snapshot.occurrence,
                            view.event_cut,
                            .{
                                .historical = try checked.observer_successors.histories.get(
                                    parent.id,
                                    view.event_cut,
                                ),
                            },
                        ),
                    ),
                )) return error.InvalidArchive;
            }
        }
        fn validateControllerViewMessages(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            view: contracts.controller.OwnerView,
        ) !void {
            if (view.messages.items.len != view.next_message - 1) return error.InvalidArchive;
            const found = try a.alloc(bool, view.messages.items.len);
            @memset(found, false);
            var rows = try store(self).database.prepare(
                "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body W" ++
                    "HERE r.task=? AND r.kind='message'",
                &.{.{ .blob = &parent.id }},
            );
            defer rows.deinit();
            while (try rows.step() == .row) {
                var saved_message = try contracts.decodeOwned(state.Message, a, try rows.bytes(0));
                defer saved_message.deinit();
                if (saved_message.value.ordinal >= view.next_message) continue;
                if (saved_message.value.ordinal == 0) return error.InvalidArchive;
                const i: usize = @intCast(saved_message.value.ordinal - 1);
                if (found[i] or !same(
                    view.messages.items[i].bytes,
                    try store(self).object(a, saved_message.value.value, null),
                )) return error.InvalidArchive;
                found[i] = true;
            }
            for (found) |present| if (!present) return error.InvalidArchive;
        }
        pub fn validateControllerMessageCut(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            event_cut: u64,
            expected_next_message: u64,
        ) !void {
            if (event_cut == 0 or event_cut > parent.event_high or expected_next_message == 0 or
                expected_next_message > parent.next_message)
                return error.InvalidArchive;
            var next_message: u64 = 1;
            var events = try store(self).database.prepare(
                "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                    "ERE e.task=? AND e.seq<=?",
                &.{ .{ .blob = &parent.id }, .{
                    .integer = std.math.cast(i64, event_cut) orelse return error.InvalidArchive,
                } },
            );
            defer events.deinit();
            while (try events.step() == .row) {
                var saved = try contracts.decodeOwned(state.Event, a, try events.bytes(0));
                defer saved.deinit();
                if (saved.value.kind == .message_queued) next_message =
                    try std.math.add(u64, next_message, 1);
            }
            if (next_message != expected_next_message) return error.InvalidArchive;
        }
    };
}
