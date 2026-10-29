const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const Occurrence = occurrence.Occurrence;
const storage = @import("../store.zig");
const registry = @import("../registry.zig");
const json = @import("../json.zig");
const workspace = @import("../workspace_state.zig");
const build_job = @import("../workspace_build.zig");
const task_types = @import("types.zig");
const OccurrenceSubject = task_types.OccurrenceSubject;
const RecoveryCompletion = task_types.RecoveryCompletion;
const Step = task_types.Step;
const Work = task_types.Work;
const WorkResult = task_types.WorkResult;
const name = task_types.name;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const controller_context_ops = @import("controller_context.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Succession = @import("controller_succession.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const reconciliation_ops = @import("reconciliation.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Root = @import("root_execution.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Builds = @import("workspace_builds.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Replay = @import("workspace_replay.zig").Operations(Types, Self);
        const Decoded = contracts.Decoded;
        const InboxReply = contracts.InboxReply;
        const awaiting = occurrence.awaiting;
        const blockedOccurrence = Root.blockedOccurrence;
        const canonical = json.canonical;
        const controllerAt = Controller.controllerAt;
        const controllerBinding = Controller.controllerBinding;
        const controllerEpochAt = Controller.controllerEpochAt;
        const controllerInternal = controller_context_ops.controllerInternal;
        const controllerOverlay = controller_context_ops.controllerOverlay;
        const decodeOwned = contracts.decodeOwned;
        const digest = storage.digest;
        const dispatchController = Succession.dispatchController;
        const dispatchWorkspace = Builds.dispatchWorkspace;
        const effectSchedule = Root.effectSchedule;
        const encodeOwned = contracts.encodeOwned;
        const event = Records.event;
        const interpretWorkspaceBuild = Builds.interpretWorkspaceBuild;
        const occurrenceImage = Root.occurrenceImage;
        const occurrenceSubject = Root.occurrenceSubject;
        const persist = Records.persist;
        const persistOccurrence = Root.persistOccurrence;
        const record = Records.record;
        const refreshControllerOverlay = Succession.refreshControllerOverlay;
        const requireCustody = Lifecycle.requireCustody;
        const resourceIdentity = registry.resourceIdentity;
        const retire = Lifecycle.retire;
        const runnableRemove = Scheduling.runnableRemove;
        const snapshotRecord = Records.snapshotRecord;
        const store = Lifecycle.store;
        const subjectPublicationEvent = Records.subjectPublicationEvent;
        const subjectRemove = Scheduling.subjectRemove;
        const task = Tasks.task;
        const validateSemanticReadPosition = Builds.validateSemanticReadPosition;
        const workspaceWork = Programs.workspaceWork;
        pub fn dispatch(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: Occurrence,
        ) !Step {
            const request_bytes = try store(self).object(a, pending.request_object, null);
            defer a.free(request_bytes);
            var request = try data.invocation.decode(data.invocation.Request, a, request_bytes);
            defer request.deinit();
            const subject = try occurrenceSubject(self, a, initial, pending);
            if (!same(&request.value.request_identity, &pending.request)) return error.CorruptState;
            if (pending.residual != null and controllerInternal(
                request.value.binding.semantic_identity,
            )) return blockedOccurrence(self, a, initial, pending, .denied);
            if (controllerInternal(
                request.value.binding.semantic_identity,
            )) return dispatchController(self, a, initial, pending, request.value, subject);
            const entry = self.handlers.admit(
                request.value,
                self.profile.authority,
                subject.image,
                resourceIdentity(
                    self.application.image_identity,
                    initial.profile.digest,
                    initial.resources.items,
                ),
            ) catch |err|
                return blockedOccurrence(
                    self,
                    a,
                    initial,
                    pending,
                    if (err == error.Denied) .denied else .missing_capability,
                );
            if (entry.declaration.kind != .leaf and
                (pending.work != null or
                    (pending.residual != null and entry.declaration.kind != .workspace)))
                return blockedOccurrence(self, a, initial, pending, .missing_capability);
            if (pending.residual != null and entry.declaration.inference)
                return blockedOccurrence(self, a, initial, pending, .denied);
            if (entry.declaration.kind == .leaf and self.work != null) return .idle;
            return dispatchAdmitted(
                self,
                a,
                initial,
                pending,
                request.value,
                request_bytes,
                subject,
                entry,
            );
        }
        fn dispatchQuestion(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            value: *state.Task,
            pending: Occurrence,
            binding: occurrence.Binding,
            attempt: state.Digest,
            entry: registry.Entry,
            request: data.invocation.Request,
            request_bytes: []const u8,
        ) !Step {
            const task_name = std.fmt.bytesToHex(value.id, .lower);
            const ctx: registry.Context = .{
                .allocator = a,
                .io = self.io,
                .authority = &self.profile.authority,
                .task_id = &task_name,
                .profile = self.profile.bytes,
                .environment = self.profile.environment,
            };
            const prompt = try canonical(
                a,
                try entry.declaration.present.?(ctx, request.binding.payload),
            );
            defer a.free(prompt);
            var question_id: state.Digest = undefined;
            try self.io.randomSecure(&question_id);
            const waiting = try awaiting(
                pending,
                binding,
                .{
                    .attempt = attempt,
                    .question = question_id,
                    .pending_digest = request.binding.pending_state_digest,
                },
                initial.cancellation != null and !initial.cancellation_applied,
            );
            return publishQuestion(
                self,
                a,
                initial,
                value,
                pending,
                entry,
                request,
                request_bytes,
                prompt,
                question_id,
                waiting,
            );
        }
        fn publishQuestion(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            value: *state.Task,
            pending: Occurrence,
            entry: registry.Entry,
            request: data.invocation.Request,
            request_bytes: []const u8,
            prompt: []const u8,
            question_id: state.Digest,
            waiting: Occurrence,
        ) !Step {
            try store(self).begin();
            defer store(self).rollback();
            const question: state.Question = .{
                .id = question_id,
                .task = value.id,
                .occurrence = pending.id,
                .revision = 1,
                .request_digest = pending.request,
                .pending_digest = request.binding.pending_state_digest,
                .answer_schema_id = try name(entry.declaration.answer_schema_id.?),
                .answer_schema_digest = digest(entry.resume_schema),
                .request = try store(self).putObject(request_bytes),
                .prompt = try store(self).putObject(prompt),
                .answer = null,
                .receipt = null,
                .retired = false,
            };
            try store(self).createRecord(
                state.Question,
                "question",
                question_id,
                value.id,
                question,
            );
            try store(self).putRecord(
                Occurrence,
                "occurrence",
                pending.id,
                value.id,
                waiting,
            );
            const event_data = try state.questionData(a, question, prompt);
            const event_bytes = try canonical(a, event_data);
            defer a.free(event_bytes);
            try event(self, value, .input_required, event_bytes);
            try persist(self, a, value.*, initial.revision, "question.awaiting", .preserve);
            runnableRemove(self, value.id);
            try retire(self, a);
            return .waiting;
        }
        fn dispatchInbox(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            value: state.Task,
            pending: Occurrence,
            binding: occurrence.Binding,
            attempt: state.Digest,
            dispatched: Occurrence,
        ) !Step {
            var message_decoded: ?Decoded(state.Message) = null;
            defer if (message_decoded) |*item| item.deinit();
            var message_value: ?Decoded(Types.Message) = null;
            defer if (message_value) |*item| item.deinit();
            var input: InboxReply(Types.Message) = .empty;
            var message_name: [64]u8 = undefined;
            if (value.messages.items.len != 0) {
                message_decoded = try record(
                    self,
                    state.Message,
                    a,
                    "message",
                    value.messages.items[0],
                    value.id,
                );
                const saved = &message_decoded.?.value;
                if (saved.disposition != .queued or saved.occurrence != null)
                    return error.CorruptState;
                const message_bytes = try store(self).object(a, saved.value, null);
                defer a.free(message_bytes);
                message_value = try decodeOwned(Types.Message, a, message_bytes);
                message_name = std.fmt.bytesToHex(saved.id, .lower);
                input = .{ .message = .{
                    .id = .{ .bytes = &message_name },
                    .value = message_value.?.value,
                } };
                saved.disposition = .acquired;
                saved.occurrence = pending.id;
            }
            return publishInbox(
                self,
                a,
                initial,
                value,
                pending,
                binding,
                attempt,
                dispatched,
                input,
                message_decoded,
            );
        }
        fn publishInbox(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            value: state.Task,
            pending: Occurrence,
            binding: occurrence.Binding,
            attempt: state.Digest,
            dispatched: Occurrence,
            input: InboxReply(Types.Message),
            message_decoded: ?Decoded(state.Message),
        ) !Step {
            const payload =
                try encodeOwned(InboxReply(Types.Message), a, input);
            defer a.free(payload);
            const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{
                .request_identity = pending.request,
                .value = payload,
            });
            defer a.free(bound);
            const acquired =
                try occurrence.acquired(dispatched, binding, attempt, digest(bound));
            try store(self).begin();
            defer store(self).rollback();
            _ = try store(self).putObject(bound);
            if (message_decoded) |saved| try store(self).putRecord(
                state.Message,
                "message",
                saved.value.id,
                value.id,
                saved.value,
            );
            try store(self).putRecord(
                Occurrence,
                "occurrence",
                pending.id,
                value.id,
                acquired,
            );
            try persist(self, a, value, initial.revision, "inbox.acquire", .preserve);
            return .progressed;
        }
        fn dispatchLeaf(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            value: state.Task,
            pending: Occurrence,
            dispatched: Occurrence,
            entry: registry.Entry,
            request: data.invocation.Request,
            request_bytes: []const u8,
        ) !Step {
            if (entry.declaration.inference and try refreshControllerOverlay(
                self,
                a,
                initial,
                pending,
            )) return .progressed;
            var preparation = std.heap.ArenaAllocator.init(a);
            defer preparation.deinit();
            const prepared =
                if (entry.declaration.capture) |adapter|
                    prepareProjection(
                        self,
                        preparation.allocator(),
                        value,
                        pending,
                        adapter,
                        try entry.payload(preparation.allocator(), request.binding.payload),
                    ) catch |err|
                        return blockedOccurrence(
                            self,
                            a,
                            initial,
                            pending,
                            switch (err) {
                                error.Capacity, error.OutOfMemory => .capacity,
                                error.MissingArtifact, error.CorruptObject => .missing_artifact,
                                else => .incompatible_profile,
                            },
                        )
                else
                    null;
            return dispatchAcquisition(
                self,
                a,
                initial,
                dispatched,
                entry,
                request_bytes,
                prepared,
                .environment,
                null,
            );
        }
        fn dispatchAdmitted(
            self: *Self,
            a: std.mem.Allocator,
            root: state.Task,
            pending: Occurrence,
            request: data.invocation.Request,
            request_bytes: []const u8,
            subject: OccurrenceSubject,
            entry: registry.Entry,
        ) !Step {
            var attempt: state.Digest = undefined;
            try self.io.randomSecure(&attempt);
            const bound: occurrence.Binding = .{
                .id = pending.id,
                .task = pending.task,
                .work = pending.work,
                .residual = pending.residual,
                .request = pending.request,
            };
            const next = try occurrence.dispatch(
                pending,
                bound,
                attempt,
                subject.cancelling,
                subject.cleanup,
            );
            var value = root;
            value.revision = try std.math.add(u64, value.revision, 1);
            if (pending.work == null and pending.residual == null) value.schedule = .active;
            switch (entry.declaration.kind) {
                .workspace => return dispatchWorkspace(
                    self,
                    a,
                    root,
                    next,
                    entry,
                    request.binding.payload,
                ),
                .question => return dispatchQuestion(
                    self,
                    a,
                    root,
                    &value,
                    pending,
                    bound,
                    attempt,
                    entry,
                    request,
                    request_bytes,
                ),
                .inbox => return dispatchInbox(self, a, root, value, pending, bound, attempt, next),
                .leaf => return dispatchLeaf(
                    self,
                    a,
                    root,
                    value,
                    pending,
                    next,
                    entry,
                    request,
                    request_bytes,
                ),
            }
        }
        pub fn dispatchAcquisition(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: Occurrence,
            entry: registry.Entry,
            request_bytes: []const u8,
            prepared: ?[]const u8,
            operation_kind: state.AttemptOperation,
            controller_read: ?state.ControllerReadCut,
        ) !Step {
            try requireCustody(self, a, initial.id, pending.work);
            if (self.work != null) return .idle;
            const subject = try occurrenceSubject(self, a, initial, pending);
            // Consume the already-authorized transition. Preparation and
            // settlement cannot reconstruct a different cancellation policy.
            const attempt = switch (pending.state) {
                .dispatching => |dispatching| dispatching.id,
                else => return error.UnsettledOccurrence,
            };
            var value = initial;
            value.revision = try std.math.add(u64, value.revision, 1);
            if (pending.work == null and pending.residual == null) value.schedule = .active;
            try chargeAcquisition(&value, entry, prepared, request_bytes);
            var controller_context: ?state.ControllerContext = null;
            const work = try acquisitionWork(
                self,
                a,
                initial,
                pending,
                entry,
                request_bytes,
                prepared,
                operation_kind,
                &controller_context,
                subject,
                attempt,
            );
            errdefer self.allocator.free(work.request);
            errdefer if (work.prepared) |body| self.allocator.free(body);
            errdefer self.allocator.free(work.profile);
            return publishAcquisition(
                self,
                a,
                initial,
                &value,
                pending,
                entry,
                request_bytes,
                prepared,
                operation_kind,
                controller_read,
                controller_context,
                attempt,
                work,
            );
        }
        fn chargeAcquisition(
            value: *state.Task,
            entry: registry.Entry,
            prepared: ?[]const u8,
            request_bytes: []const u8,
        ) !void {
            const charged_bytes = if (prepared) |body| body.len else request_bytes.len;
            if (entry.declaration.inference) {
                value.inference_attempts = try std.math.add(u64, value.inference_attempts, 1);
                value.inference_request_bytes = try std.math.add(
                    u64,
                    value.inference_request_bytes,
                    charged_bytes,
                );
            }
        }
        fn acquisitionWork(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: Occurrence,
            entry: registry.Entry,
            request_bytes: []const u8,
            prepared: ?[]const u8,
            operation_kind: state.AttemptOperation,
            controller_context: *?state.ControllerContext,
            subject: OccurrenceSubject,
            attempt: state.Digest,
        ) !Work {
            const retained = try self.allocator.dupe(u8, request_bytes);
            errdefer self.allocator.free(retained);
            const retained_prepared =
                if (prepared) |body| try self.allocator.dupe(u8, body) else null;
            errdefer if (retained_prepared) |body| self.allocator.free(body);
            const retained_profile = try self.allocator.dupe(u8, self.profile.bytes);
            errdefer self.allocator.free(retained_profile);
            controller_context.* = try currentControllerContext(self, a, initial, pending);
            return .{
                .owner_epoch = self.owner_epoch,
                .task = initial.id,
                .subject_work = pending.work,
                .subject_residual = pending.residual,
                .occurrence = pending.id,
                .attempt = attempt,
                .request = retained,
                .prepared = retained_prepared,
                .profile = retained_profile,
                .entry = entry,
                .operation = operation_kind,
                .controller_projection = (try projectionBindingAt(
                    self,
                    a,
                    initial,
                    pending,
                    controller_context.*,
                )).controller,
                .cleanup = subject.cleanup,
            };
        }
        fn acquisitionReadEvent(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            value: *state.Task,
            pending: Occurrence,
            controller_read: ?state.ControllerReadCut,
            attempt: state.Digest,
            input: Decoded(build_job.Input),
        ) !void {
            try validateSemanticReadPosition(
                input.value.derive.basis,
                try std.math.add(u64, initial.event_high, 1),
            );
            try Replay.validateControllerReadCut(input.value.derive.basis, controller_read);
            const event_data = try std.fmt.allocPrint(
                a,
                "{{\"attempt_id\":\"{s}\",\"occurrence_id\":\"{s}\"}}",
                .{
                    std.fmt.bytesToHex(attempt, .lower),
                    std.fmt.bytesToHex(pending.id, .lower),
                },
            );
            defer a.free(event_data);
            try subjectPublicationEvent(
                self,
                value,
                .workspace_read,
                event_data,
                &.{},
                &.{},
                null,
                controller_read,
                null,
            );
        }
        fn publishAcquisition(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            value: *state.Task,
            pending: Occurrence,
            entry: registry.Entry,
            request_bytes: []const u8,
            prepared: ?[]const u8,
            operation_kind: state.AttemptOperation,
            controller_read: ?state.ControllerReadCut,
            controller_context: ?state.ControllerContext,
            attempt: state.Digest,
            work: Work,
        ) !Step {
            var compiler_input: ?Decoded(build_job.Input) = null;
            defer if (compiler_input) |*input| input.deinit();
            if (operation_kind == .workspace_build)
                compiler_input = try decodeOwned(
                    build_job.Input,
                    a,
                    prepared orelse return error.CorruptState,
                );
            const reads_mutable = if (compiler_input) |input|
                input.value == .derive and input.value.derive.basis != .immutable
            else
                false;
            try store(self).begin();
            defer store(self).rollback();
            try store(self).createRecord(state.Attempt, "attempt", attempt, value.id, .{
                .id = attempt,
                .task = value.id,
                .occurrence = pending.id,
                .request = try store(self).putObject(request_bytes),
                .profile = value.profile,
                .capability = try name(entry.declaration.identity),
                .operation = operation_kind,
                .inference = entry.declaration.inference,
                .prepared = if (prepared) |body| try store(self).putObject(body) else null,
                .controller_context = controller_context,
                .controller_read = controller_read,
                .dispatch_checkpoint = if (reads_mutable) initial.checkpoint else null,
            });
            try store(self).putRecord(
                Occurrence,
                "occurrence",
                pending.id,
                value.id,
                pending,
            );
            if (reads_mutable) try acquisitionReadEvent(
                self,
                a,
                initial,
                value,
                pending,
                controller_read,
                attempt,
                compiler_input.?,
            );
            try effectSchedule(self, a, value, pending, .active, null);
            try persist(self, a, value.*, initial.revision, "effect.dispatch", .preserve);
            self.work = work;
            subjectRemove(self, .{
                .task = value.id,
                .work = pending.work,
                .residual = pending.residual,
            });
            return .{ .work = work };
        }
        pub fn projectionBinding(self: *Self, value: state.Task) registry.ProjectionBinding {
            return .{
                .task = value.id,
                .tenant = value.tenant.bytes,
                .profile = self.profile.bytes,
                .application = self.application.image_identity,
                .resources = value.resources.items,
            };
        }
        pub fn occurrenceProjectionBinding(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            pending: Occurrence,
        ) !registry.ProjectionBinding {
            const attempt_id: ?state.Digest = switch (pending.state) {
                .dispatching, .unknown, .not_sent, .captured => |item| item.id,
                .settled_reply => |item| item.attempt,
                .admitted => |item| if (item == .reply) item.reply.attempt else null,
                else => null,
            };
            if (attempt_id) |id| {
                var attempt = try record(self, state.Attempt, a, "attempt", id, value.id);
                defer attempt.deinit();
                if (!std.meta.eql(attempt.value.occurrence, pending.id)) return error.CorruptState;
                return projectionBindingAt(
                    self,
                    a,
                    value,
                    pending,
                    attempt.value.controller_context,
                );
            }
            return projectionBindingAt(
                self,
                a,
                value,
                pending,
                try currentControllerContext(self, a, value, pending),
            );
        }
        fn currentControllerContext(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            pending: Occurrence,
        ) !?state.ControllerContext {
            if (pending.work != null or pending.residual != null) return null;
            var route = try record(
                self,
                workspace.ExecutionRoute,
                a,
                "execution_route",
                pending.id,
                value.id,
            );
            defer route.deinit();
            const id = route.value.interaction orelse return null;
            var interaction = try record(
                self,
                state.ControllerInteraction,
                a,
                "controller_interaction",
                id,
                value.id,
            );
            defer interaction.deinit();
            return .{
                .epoch = interaction.value.epoch,
                .event_cut = interaction.value.event_cut,
                .next_message = interaction.value.next_message,
                .overlay = interaction.value.overlay,
            };
        }
        pub fn projectionBindingAt(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            pending: Occurrence,
            context: ?state.ControllerContext,
        ) !registry.ProjectionBinding {
            var binding = projectionBinding(self, value);
            binding.execution = try occurrenceImage(self, a, value, pending);
            if ((pending.work != null or pending.residual != null) and context != null)
                return error.InvalidControllerBinding;
            if (pending.work) |id| {
                var child = try workspaceWork(self, a, value.id, id);
                defer child.deinit();
                if (child.value.trial) |trial_id| {
                    var trial = try record(
                        self,
                        workspace.Trial,
                        a,
                        "workspace_trial",
                        trial_id,
                        value.id,
                    );
                    defer trial.deinit();
                    binding.trial = .{ .work = id, .view = trial.value.view };
                }
                return binding;
            }
            if (pending.residual != null) return binding;
            var route = try record(
                self,
                workspace.ExecutionRoute,
                a,
                "execution_route",
                pending.id,
                value.id,
            );
            defer route.deinit();
            if (route.value.interaction) |id| {
                binding.controller = try controllerProjectionAt(
                    self,
                    a,
                    value,
                    pending,
                    context,
                    id,
                    route.value.controller,
                );
            } else if (context != null) return error.InvalidControllerBinding;
            return binding;
        }
        fn controllerProjectionAt(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            pending: Occurrence,
            context: ?state.ControllerContext,
            id: state.Digest,
            controller_id: ?state.Digest,
        ) !@FieldType(registry.ProjectionBinding, "controller") {
            var interaction = try record(
                self,
                state.ControllerInteraction,
                a,
                "controller_interaction",
                id,
                value.id,
            );
            defer interaction.deinit();
            if (!std.meta.eql(controller_id, interaction.value.controller) or !std.meta.eql(
                interaction.value.model,
                pending.id,
            )) return error.InvalidControllerBinding;
            const controller =
                try controllerBinding(self, a, value, interaction.value.controller);
            const captured = context orelse return error.InvalidControllerBinding;
            if (captured.next_message > value.next_message or !std.meta.eql(
                @as(?state.Digest, controller.id),
                try controllerAt(self, a, value, captured.event_cut),
            ) or captured.epoch != try controllerEpochAt(
                self,
                a,
                value,
                captured.event_cut,
            )) return error.InvalidControllerBinding;
            const expected = try controllerOverlay(
                self,
                a,
                value,
                controller.id,
                id,
                captured.event_cut,
                captured.next_message,
                captured.epoch,
            );
            defer a.free(expected);
            if (!std.meta.eql(captured.overlay, state.Reference{
                .digest = digest(expected),
                .bytes = expected.len,
            })) return error.InvalidControllerBinding;
            return .{
                .binding = controller.id,
                .epoch = captured.epoch,
                .program = controller.program_identity,
                .overlay = captured.overlay,
            };
        }
        pub fn prepareProjection(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            pending: Occurrence,
            adapter: registry.CaptureAdapter,
            payload: []const u8,
        ) ![]u8 {
            return store(self).project(
                []u8,
                a,
                self.handlers,
                try occurrenceProjectionBinding(self, a, value, pending),
                struct {
                    adapter: registry.CaptureAdapter,
                    payload: []const u8,
                    pub fn run(this: @This(), context: registry.ProjectionContext) ![]u8 {
                        return this.adapter.prepare(context, this.payload);
                    }
                }{ .adapter = adapter, .payload = payload },
            );
        }
        pub fn interpretProjection(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            pending: Occurrence,
            adapter: registry.CaptureAdapter,
            payload: []const u8,
            prepared: []const u8,
            response: []const u8,
        ) !registry.Projection {
            return store(self).project(
                registry.Projection,
                a,
                self.handlers,
                try occurrenceProjectionBinding(self, a, value, pending),
                struct {
                    adapter: registry.CaptureAdapter,
                    payload: []const u8,
                    prepared: []const u8,
                    response: []const u8,
                    pub fn run(
                        this: @This(),
                        context: registry.ProjectionContext,
                    ) !registry.Projection {
                        return this.adapter.interpret(
                            context,
                            this.payload,
                            this.prepared,
                            this.response,
                        );
                    }
                }{
                    .adapter = adapter,
                    .payload = payload,
                    .prepared = prepared,
                    .response = response,
                },
            );
        }
        fn capture(self: *Self, a: std.mem.Allocator, work: Work, raw: []const u8) !void {
            defer releaseWork(self);
            errdefer store(self).fence();
            // Publication failure fences this owner. The durable dispatched
            // occurrence then recovers as unknown, never as permission to retry.
            if (work.prepared == null) return error.InvalidPreparedRequest;
            var decoded = try task(self, a, work.task);
            defer decoded.deinit();
            var value = decoded.value;
            var saved =
                try record(self, Occurrence, a, "occurrence", work.occurrence, work.task);
            defer saved.deinit();
            const next = try occurrence.captured(
                saved.value,
                .{
                    .id = work.occurrence,
                    .task = work.task,
                    .work = work.subject_work,
                    .residual = work.subject_residual,
                    .request = saved.value.request,
                },
                work.attempt,
            );
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            try store(self).begin();
            defer store(self).rollback();
            try store(self).createRecord(state.Capture, "capture", work.attempt, work.task, .{
                .task = work.task,
                .occurrence = work.occurrence,
                .attempt = work.attempt,
                .request = try store(self).putObject(work.prepared.?),
                .response = try store(self).putObject(raw),
                .disposition = .complete,
            });
            try store(self).putRecord(
                Occurrence,
                "occurrence",
                work.occurrence,
                work.task,
                next,
            );
            try effectSchedule(self, a, &value, saved.value, .queued, null);
            try persistOccurrence(self, a, value, previous, "effect.capture", saved.value, true);
        }
        pub fn interpretCapture(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: Occurrence,
        ) !Step {
            try requireCustody(self, a, initial.id, pending.work);
            const attempt_id = pending.state.captured.id;
            var attempt =
                try record(self, state.Attempt, a, "attempt", attempt_id, initial.id);
            defer attempt.deinit();
            var raw = try record(self, state.Capture, a, "capture", attempt_id, initial.id);
            defer raw.deinit();
            try validateCapturedAttempt(initial, pending, attempt.value, raw.value);
            const encoded = try store(self).object(a, attempt.value.request, null);
            defer a.free(encoded);
            var request = try data.invocation.decode(data.invocation.Request, a, encoded);
            defer request.deinit();
            if (!same(&request.value.request_identity, &pending.request)) return error.CorruptState;
            // Resolve the original schemas without acquiring another I/O grant.
            const entry = try self.handlers.resolve(
                request.value,
                (try occurrenceSubject(self, a, initial, pending)).image,
            );
            if (attempt.value.operation == .workspace_build) return interpretWorkspaceBuild(
                self,
                a,
                initial,
                pending,
                attempt.value,
                raw.value,
            );
            const adapter = entry.declaration.capture orelse return error.IncompatibleProfile;
            const rendered = try store(self).object(a, raw.value.request, null);
            defer a.free(rendered);
            const response = try store(self).object(a, raw.value.response.?, null);
            defer a.free(response);
            var projection_arena = std.heap.ArenaAllocator.init(a);
            defer projection_arena.deinit();
            const result = interpretProjection(
                self,
                projection_arena.allocator(),
                initial,
                pending,
                adapter,
                try entry.payload(projection_arena.allocator(), request.value.binding.payload),
                rendered,
                response,
            ) catch
                return blockedOccurrence(self, a, initial, pending, .unavailable_environment);
            var schema = try data.schema.decode(a, entry.resume_schema);
            defer schema.deinit();
            data.schema.validateValue(
                a,
                schema.descriptor,
                result.reply,
            ) catch return blockedOccurrence(self, a, initial, pending, .unavailable_environment);
            return publishInterpretedCapture(
                self,
                a,
                initial,
                pending,
                attempt_id,
                raw.value,
                entry,
                adapter,
                result,
            );
        }
        fn validateCapturedAttempt(
            initial: state.Task,
            pending: Occurrence,
            attempt: state.Attempt,
            raw: state.Capture,
        ) !void {
            if (raw.disposition != .complete or
                raw.response == null or
                raw.projection != null or
                attempt.prepared == null or
                !same(&attempt.occurrence, &pending.id) or
                !same(&raw.occurrence, &pending.id) or
                !same(&attempt.profile.digest, &initial.profile.digest) or
                !std.meta.eql(attempt.prepared.?, raw.request)) return error.CorruptState;
        }
        fn settleCaptureReconciliation(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: Occurrence,
            attempt_id: state.Digest,
            raw: state.Capture,
            reply: state.Reference,
            id: state.Digest,
        ) !void {
            var prior =
                try record(self, state.Reconciliation, a, "reconciliation", id, initial.id);
            defer prior.deinit();
            var recovery = prior.value;
            if (recovery.outcome != .capture_admitted or !same(
                &recovery.attempt,
                &attempt_id,
            ) or !same(&recovery.occurrence, &pending.id) or !std.meta.eql(
                recovery.outcome.capture_admitted,
                raw.response.?,
            )) return error.CorruptState;
            recovery.previous = try snapshotRecord(
                self,
                state.Reconciliation,
                a,
                "reconciliation",
                id,
                initial.id,
            );
            recovery.outcome = .{ .reply_settled = reply };
            try store(self).putRecord(
                state.Reconciliation,
                "reconciliation",
                id,
                initial.id,
                recovery,
            );
        }
        fn retainCaptureProjection(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            attempt_id: state.Digest,
            raw: state.Capture,
            adapter: registry.CaptureAdapter,
            result: registry.Projection,
            bound: []const u8,
        ) !state.Reference {
            const reply = try store(self).putObject(bound);
            const objects = try a.alloc(state.Reference, result.objects.len);
            defer a.free(objects);
            for (result.objects, objects) |object, *reference|
                reference.* =
                    try store(self).putObject(object);
            try store(self).retainProjection(adapter.dependencies, result.objects);
            var projected = raw;
            projected.projection = .{
                .reply = reply,
                .objects = .{ .items = objects },
                .output_tokens = result.output_tokens,
            };
            try store(self).putRecord(state.Capture, "capture", attempt_id, initial.id, projected);
            return reply;
        }
        fn publishInterpretedCapture(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            pending: Occurrence,
            attempt_id: state.Digest,
            raw: state.Capture,
            entry: registry.Entry,
            adapter: registry.CaptureAdapter,
            result: registry.Projection,
        ) !Step {
            const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{
                .request_identity = pending.request,
                .value = result.reply,
            });
            defer a.free(bound);
            const next = try capturedOccurrence(initial, pending, attempt_id, bound);
            var value = initial;
            value.revision = try std.math.add(u64, value.revision, 1);
            if (entry.declaration.inference) if (result.output_tokens) |tokens| {
                value.inference_output_tokens = std.math.add(
                    u64,
                    value.inference_output_tokens,
                    tokens,
                ) catch return blockedOccurrence(self, a, initial, pending, .capacity);
            };
            try store(self).begin();
            defer store(self).rollback();
            const reply = try retainCaptureProjection(
                self,
                a,
                initial,
                attempt_id,
                raw,
                adapter,
                result,
                bound,
            );
            try store(self).putRecord(
                Occurrence,
                "occurrence",
                pending.id,
                initial.id,
                next,
            );
            if (raw.reconciliation) |id| try settleCaptureReconciliation(
                self,
                a,
                initial,
                pending,
                attempt_id,
                raw,
                reply,
                id,
            );
            try effectSchedule(self, a, &value, pending, .queued, null);
            try persistOccurrence(
                self,
                a,
                value,
                initial.revision,
                "effect.interpret",
                pending,
                true,
            );
            return .progressed;
        }
        fn capturedOccurrence(
            initial: state.Task,
            pending: Occurrence,
            attempt_id: state.Digest,
            bound: []const u8,
        ) !Occurrence {
            return try occurrence.acquired(
                pending,
                .{
                    .id = pending.id,
                    .task = initial.id,
                    .work = pending.work,
                    .residual = pending.residual,
                    .request = pending.request,
                },
                attempt_id,
                digest(bound),
            );
        }
        fn currentWork(self: *Self, work: Work) !void {
            const current = self.work orelse return error.StaleOccurrence;
            if (!same(&self.owner_epoch, &work.owner_epoch) or
                !same(&current.owner_epoch, &work.owner_epoch) or
                !same(&current.task, &work.task) or !std.meta.eql(
                current.subject_work,
                work.subject_work,
            ) or !std.meta.eql(
                current.subject_residual,
                work.subject_residual,
            ) or current.operation != work.operation or !same(
                &current.occurrence,
                &work.occurrence,
            ) or !same(&current.attempt, &work.attempt)) return error.StaleOccurrence;
            if ((current.recovery != null) != (work.recovery != null)) return error.StaleOccurrence;
            if (current.recovery) |item| if (!same(
                &item.id,
                &work.recovery.?.id,
            )) return error.StaleOccurrence;
        }
        fn releaseWork(self: *Self) void {
            self.allocator.free(self.work.?.request);
            if (self.work.?.prepared) |body| self.allocator.free(body);
            self.allocator.free(self.work.?.profile);
            if (self.work.?.recovery) |item| self.allocator.free(item.body);
            self.work = null;
        }
        pub fn shouldCancelWork(self: *Self, work: Work) !bool {
            try currentWork(self, work);
            return (work.recovery != null or !work.cleanup) and self.work.?.cancel_requested;
        }
        pub fn completeWork(
            self: *Self,
            a: std.mem.Allocator,
            work: Work,
            result: WorkResult,
        ) !void {
            // All front ends publish a joined worker through this same owner.
            try currentWork(self, work);
            try requireCustody(self, a, work.task, work.subject_work);
            switch (result) {
                .acquired => |bytes| return acquire(self, a, work, bytes),
                .not_sent => return notSent(self, a, work),
                .unknown => return unknown(self, a, work),
                .rederived => |finding| {
                    try currentWork(self, work);
                    if (work.recovery == null) return error.InvalidRecovery;
                    return completeRecoveryWork(self, a, work, .{ .rederived = finding });
                },
                .failure => |err| {
                    try currentWork(self, work);
                    releaseWork(self);
                    store(self).fence();
                    return err;
                },
            }
        }
        fn completeRecoveryWork(
            self: *Self,
            a: std.mem.Allocator,
            work: Work,
            completion: ?RecoveryCompletion,
        ) !void {
            try currentWork(self, work);
            defer releaseWork(self);
            errdefer store(self).fence();
            var value = try task(self, a, work.task);
            defer value.deinit();
            var pending = try record(
                self,
                Occurrence,
                a,
                "occurrence",
                work.occurrence,
                work.task,
            );
            defer pending.deinit();
            var item = try record(
                self,
                state.Reconciliation,
                a,
                "reconciliation",
                work.recovery.?.id,
                work.task,
            );
            defer item.deinit();
            if (item.value.owner_epoch == null or !same(
                &item.value.owner_epoch.?,
                &work.owner_epoch,
            ) or !same(&item.value.attempt, &work.attempt) or !same(
                &item.value.occurrence,
                &work.occurrence,
            )) return error.StaleOccurrence;
            try reconciliation_ops.finishRecovery(
                self,
                a,
                value.value,
                pending.value,
                item.value,
                completion,
                .unavailable,
            );
        }
        pub fn acquire(self: *Self, a: std.mem.Allocator, work: Work, reply: []const u8) !void {
            // A worker has returned and will no longer access this work item.
            // Acquisition is published before any subsequent Kosmos consumption.
            try currentWork(self, work);
            try requireCustody(self, a, work.task, work.subject_work);
            if (work.recovery != null) return completeRecoveryWork(self, a, work, .{
                .evidence = reply,
            });
            if (work.operation == .workspace_build or work.entry.declaration.capture != null)
                return capture(self, a, work, reply);
            defer releaseWork(self);
            errdefer store(self).fence();
            var schema = try data.schema.decode(a, work.entry.resume_schema);
            defer schema.deinit();
            try data.schema.validateValue(a, schema.descriptor, reply);
            var decoded = try task(self, a, work.task);
            defer decoded.deinit();
            var value = decoded.value;
            var saved =
                try record(self, Occurrence, a, "occurrence", work.occurrence, work.task);
            defer saved.deinit();
            const binding: occurrence.Binding = .{
                .id = work.occurrence,
                .task = work.task,
                .work = work.subject_work,
                .residual = work.subject_residual,
                .request = saved.value.request,
            };
            const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{
                .request_identity = saved.value.request,
                .value = reply,
            });
            defer a.free(bound);
            const acquired =
                try occurrence.acquired(saved.value, binding, work.attempt, digest(bound));
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            try store(self).begin();
            defer store(self).rollback();
            _ = try store(self).putObject(bound);
            try store(self).putRecord(
                Occurrence,
                "occurrence",
                work.occurrence,
                work.task,
                acquired,
            );
            try effectSchedule(self, a, &value, saved.value, .queued, null);
            try persistOccurrence(self, a, value, previous, "effect.acquire", saved.value, true);
        }
        pub fn unknown(self: *Self, a: std.mem.Allocator, work: Work) !void {
            try currentWork(self, work);
            try requireCustody(self, a, work.task, work.subject_work);
            if (work.recovery != null) return completeRecoveryWork(self, a, work, null);
            defer releaseWork(self);
            errdefer store(self).fence();
            var decoded = try task(self, a, work.task);
            defer decoded.deinit();
            var value = decoded.value;
            var saved =
                try record(self, Occurrence, a, "occurrence", work.occurrence, work.task);
            defer saved.deinit();
            const binding: occurrence.Binding = .{
                .id = work.occurrence,
                .task = work.task,
                .work = work.subject_work,
                .residual = work.subject_residual,
                .request = saved.value.request,
            };
            const lost = try occurrence.unknown(saved.value, binding, work.attempt);
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            if (work.subject_work == null and work.subject_residual == null) {
                value.schedule = .parked;
                value.blocker = .unavailable_environment;
            }
            try store(self).begin();
            defer store(self).rollback();
            try store(self).putRecord(
                Occurrence,
                "occurrence",
                work.occurrence,
                work.task,
                lost,
            );
            if (work.subject_work == null and work.subject_residual == null) try event(
                self,
                &value,
                .delivery_unknown,
                "{}",
            );
            try effectSchedule(self, a, &value, saved.value, .parked, .unavailable_environment);
            try persist(self, a, value, previous, "effect.unknown", .preserve);
            subjectRemove(self, .{
                .task = work.task,
                .work = work.subject_work,
                .residual = work.subject_residual,
            });
            try retire(self, a);
        }
        pub fn notSent(self: *Self, a: std.mem.Allocator, work: Work) !void {
            try currentWork(self, work);
            try requireCustody(self, a, work.task, work.subject_work);
            if (work.recovery != null) return completeRecoveryWork(self, a, work, null);
            defer releaseWork(self);
            errdefer store(self).fence();
            var decoded = try task(self, a, work.task);
            defer decoded.deinit();
            var value = decoded.value;
            var saved =
                try record(self, Occurrence, a, "occurrence", work.occurrence, work.task);
            defer saved.deinit();
            const next = try occurrence.notSent(
                saved.value,
                .{
                    .id = work.occurrence,
                    .task = work.task,
                    .work = work.subject_work,
                    .residual = work.subject_residual,
                    .request = saved.value.request,
                },
                work.attempt,
            );
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            const subject = try occurrenceSubject(self, a, value, saved.value);
            const cancelling = subject.cancelling and !subject.cleanup;
            if (cancelling) try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            if (work.subject_work == null and work.subject_residual == null) {
                value.blocker = if (cancelling) null else .unavailable_environment;
                value.schedule = if (cancelling) .queued else .parked;
            }
            try store(self).begin();
            defer store(self).rollback();
            try store(self).putRecord(
                Occurrence,
                "occurrence",
                work.occurrence,
                work.task,
                next,
            );
            if (work.subject_work == null and work.subject_residual == null) try event(
                self,
                &value,
                .blocked,
                "{\"delivery\":\"definitely_not_sent\"}",
            );
            try effectSchedule(
                self,
                a,
                &value,
                saved.value,
                if (cancelling) .queued else .parked,
                if (cancelling) null else .unavailable_environment,
            );
            try persistOccurrence(
                self,
                a,
                value,
                previous,
                "effect.not-sent",
                saved.value,
                cancelling,
            );
        }
    };
}
