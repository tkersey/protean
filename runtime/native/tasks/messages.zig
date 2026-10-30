const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const registry = @import("../registry.zig");
const json = @import("../json.zig");
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const Step = task_types.Step;
const answerDigest = task_types.answerDigest;
const name = task_types.name;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const acceptsMessages = Controller.acceptsMessages;
        const claim = Scheduling.claim;
        const compatibleApplication = admission_ops.compatibleApplication;
        const ensureOwnershipCapacity = Scheduling.ensureOwnershipCapacity;
        const event = Records.event;
        const messageEvent = Records.messageEvent;
        const operationKey = Records.operationKey;
        const persist = Records.persist;
        const persistScheduled = Records.persistScheduled;
        const receipt = Records.receipt;
        const record = Records.record;
        const replay = Records.replay;
        const requireCustody = Lifecycle.requireCustody;
        const retire = Lifecycle.retire;
        const rootProgramIdentity = Controller.rootProgramIdentity;
        const runnableRemove = Scheduling.runnableRemove;
        const store = Lifecycle.store;
        const admission_ops = @import("admission.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        pub fn messageDigest(
            a: std.mem.Allocator,
            task_id: state.TaskId,
            input: Types.Message,
        ) !state.Digest {
            const Request = struct {
                method: state.Method,
                task: state.TaskId,
                schema: state.Name,
                value: Types.Message,
            };
            return operation(Request, a, .{
                .method = .message,
                .task = task_id,
                .schema = try name(Types.message_schema_id),
                .value = input,
            });
        }
        pub fn message(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            task_id: state.TaskId,
            input: Types.Message,
        ) !Admission {
            const request = try messageDigest(a, task_id, input);
            if (try replay(self, a, id, request)) |prior| return prior;
            try requireCustody(self, a, task_id, null);
            var decoded = try self.task(a, task_id);
            defer decoded.deinit();
            var value = decoded.value;
            if (value.terminal() or value.cancellation != null) return error.TerminalTask;
            // Input belongs to the saved application's contract, independently
            // of which launch profile will eventually resume its execution.
            try compatibleApplication(self, value);
            if (!same(value.message_schema_id.bytes, Types.message_schema_id))
                return error.IncompatibleProfile;
            if (!acceptsMessages(self)) return error.UnsupportedCapability;
            const bytes = try contracts.encodeOwned(Types.Message, a, input);
            defer a.free(bytes);
            var identity: state.Digest = undefined;
            try self.io.randomSecure(&identity);
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            const ordinal = value.next_message;
            value.next_message = try std.math.add(u64, ordinal, 1);
            const queue = try a.alloc(state.Digest, value.messages.items.len + 1);
            defer a.free(queue);
            @memcpy(queue[0..value.messages.items.len], value.messages.items);
            queue[queue.len - 1] = identity;
            value.messages = .{ .items = queue };
            try store(self).begin();
            defer store(self).rollback();
            const saved: state.Message = .{
                .id = identity,
                .task = task_id,
                .ordinal = ordinal,
                .schema_id = try name(Types.message_schema_id),
                .value = try store(self).putObject(bytes),
                .disposition = .queued,
                .occurrence = null,
            };
            try store(self).createRecord(state.Message, "message", identity, task_id, saved);
            try messageEvent(self, a, &value, .message_queued, saved);
            const admitted =
                try receipt(self, a, .message, id, request, value, .queued, identity, null);
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            try persist(self, a, value, previous, "task.message", .preserve);
            return admitted;
        }
        pub fn respond(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            task_id: state.TaskId,
            question_id: state.Digest,
            revision: u64,
            request_digest: state.Digest,
            schema_id: []const u8,
            answer_json: json.Value,
        ) !Admission {
            var decoded = try self.task(a, task_id);
            defer decoded.deinit();
            const value = decoded.value;
            // Client-selected identities may be absent without corrupting the
            // store. Missing references from durable state still use record().
            const question_bytes =
                (try store(self).recordBytes(a, "question", question_id, task_id)) orelse {
                    // Missing durable current-question references remain storage
                    // corruption even when discovered during a client lookup.
                    var current = try self.pendingQuestion(a, task_id);
                    if (current) |*question| question.deinit();
                    return error.StaleInteraction;
                };
            defer a.free(question_bytes);
            var question_decoded = try contracts.decodeOwned(state.Question, a, question_bytes);
            defer question_decoded.deinit();
            const question = question_decoded.value;
            if (question.revision != revision or !same(&question.request_digest, &request_digest) or
                !same(question.answer_schema_id.bytes, schema_id)) return error.StaleInteraction;
            const answer = try encodeAnswer(self, a, schema_id, question, answer_json);
            defer a.free(answer);
            const request = try answerDigest(
                a,
                task_id,
                question_id,
                revision,
                request_digest,
                schema_id,
                answer,
            );
            if (try replay(self, a, id, request)) |prior| return prior;
            try requireCustody(self, a, task_id, null);
            if (question.answer != null)
                return replayAnswer(self, a, id, request, question, answer);
            return admitAnswer(self, a, id, request, value, question, question_id, answer);
        }
        fn encodeAnswer(
            self: *Self,
            a: std.mem.Allocator,
            schema_id: []const u8,
            question: state.Question,
            answer_json: json.Value,
        ) ![]u8 {
            var answer_bytes: ?[]u8 = null;
            for (self.handlers.entries) |entry| {
                if (entry.declaration.kind == .question and same(
                    entry.declaration.answer_schema_id.?,
                    schema_id,
                ) and same(&storage.digest(entry.resume_schema), &question.answer_schema_digest)) {
                    answer_bytes = try entry.declaration.answer.?(a, answer_json);
                    break;
                }
            }
            return answer_bytes orelse error.IncompatibleProfile;
        }
        fn replayAnswer(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            request: state.Digest,
            question: state.Question,
            answer: []const u8,
        ) !Admission {
            const saved_answer = question.answer.?;

            if (!same(&saved_answer.digest, &storage.digest(answer))) return error.AnswerConflict;
            const original = question.receipt orelse return error.CorruptState;
            const bytes = try contracts.encodeOwned(state.Receipt, a, original);
            defer a.free(bytes);
            const key = try operationKey(self, a, id);
            try store(self).begin();
            defer store(self).rollback();
            try store(self).putReceipt(&key, request, bytes);
            try self.namespace.commit("task.respond.replay");
            var retained = original;
            retained.client_operation_id = .{
                .bytes = try a.dupe(u8, original.client_operation_id.bytes),
            };
            return .{ .receipt = retained, .replayed = true };
        }
        fn admitAnswer(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            request: state.Digest,
            value: state.Task,
            question: state.Question,
            question_id: state.Digest,
            answer: []const u8,
        ) !Admission {
            const task_id = value.id;
            if (question.retired or
                value.terminal() or
                (value.cancellation != null and !value.cancellation_applied) or
                value.current_occurrence == null or
                !same(&value.current_occurrence.?, &question.occurrence))
                return error.StaleInteraction;
            try admitQuestionRequest(self, a, value, question);
            var pending = try record(
                self,
                occurrence.Occurrence,
                a,
                "occurrence",
                question.occurrence,
                task_id,
            );
            defer pending.deinit();
            const bound = try data.invocation.encodeOwned(data.invocation.Result, a, .{
                .request_identity = question.request_digest,
                .value = answer,
            });
            defer a.free(bound);
            const binding: occurrence.Binding = .{
                .id = pending.value.id,
                .task = task_id,
                .request = pending.value.request,
            };
            const acquired = try occurrence.answered(
                pending.value,
                binding,
                question_id,
                question.pending_digest,
                storage.digest(answer),
                storage.digest(bound),
                false,
            );
            try ensureOwnershipCapacity(self, task_id);
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            return publishAnswer(
                self,
                a,
                id,
                request,
                value,
                question,
                question_id,
                answer,
                bound,
                acquired,
            );
        }
        fn admitQuestionRequest(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            question: state.Question,
        ) !void {
            const original_request = try store(self).object(a, question.request, null);
            defer a.free(original_request);
            var admitted_request =
                try data.invocation.decode(data.invocation.Request, a, original_request);
            defer admitted_request.deinit();
            _ = try self.handlers.admit(
                admitted_request.value,
                self.profile.authority,
                try rootProgramIdentity(self, a, value),
                registry.resourceIdentity(
                    self.application.image_identity,
                    value.profile.digest,
                    value.resources.items,
                ),
            );
        }
        fn publishAnswer(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            request: state.Digest,
            initial: state.Task,
            original_question: state.Question,
            question_id: state.Digest,
            answer: []const u8,
            bound: []const u8,
            acquired: occurrence.Occurrence,
        ) !Admission {
            var value = initial;
            var question = original_question;
            const task_id = value.id;
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            value.schedule = .queued;
            try store(self).begin();
            defer store(self).rollback();
            question.answer = try store(self).putObject(answer);
            _ = try store(self).putObject(bound);
            try store(self).putRecord(
                occurrence.Occurrence,
                "occurrence",
                acquired.id,
                task_id,
                acquired,
            );
            try event(self, &value, .input_accepted, "{}");
            const admitted = try receipt(
                self,
                a,
                .respond,
                id,
                request,
                value,
                .answer_acquired,
                null,
                question_id,
            );
            question.receipt = admitted.receipt;
            try store(self).putRecord(state.Question, "question", question_id, task_id, question);
            try persistScheduled(
                self,
                a,
                value,
                previous,
                "task.respond",
                .preserve,
                &.{.{
                    .task = task_id,
                }},
            );
            claim(self, task_id);
            return admitted;
        }
        pub fn blocked(
            self: *Self,
            a: std.mem.Allocator,
            initial: state.Task,
            blocker: state.Blocker,
        ) !Step {
            var value = initial;
            value.revision = try std.math.add(u64, value.revision, 1);
            value.blocker = blocker;
            value.schedule = .parked;
            try store(self).begin();
            defer store(self).rollback();
            try event(self, &value, .blocked, "{}");
            try persist(self, a, value, initial.revision, "task.blocked", .preserve);
            runnableRemove(self, value.id);
            try retire(self, a);
            return .waiting;
        }
    };
}
