const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const storage = @import("../store.zig");
const evaluator = @import("../driver.zig");
const discovery = @import("../discovery.zig");
const construction = @import("../program_construction.zig");
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const name = task_types.name;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const allowed = Lifecycle.allowed;
        const claim = Scheduling.claim;
        const createCustody = Lifecycle.createCustody;
        const ensureOwnershipCapacity = Scheduling.ensureOwnershipCapacity;
        const operationKey = Records.operationKey;
        const receipt = Records.receipt;
        const replay = Records.replay;
        const retire = Lifecycle.retire;
        const runnableAppendAssumeCapacity = Scheduling.runnableAppendAssumeCapacity;
        const store = Lifecycle.store;
        const workspaceStoreProgram = Programs.workspaceStoreProgram;
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        pub fn compatibleApplication(self: *Self, value: state.Task) !void {
            if (!same(value.application_id.bytes, Types.application_id) or
                !same(&value.image.digest, &storage.digest(self.assets.image)))
                return error.IncompatibleProfile;
            if ((self.application.controller != null) != (value.controller != null))
                return error.IncompatibleProfile;
        }
        pub fn submitDigest(
            a: std.mem.Allocator,
            profile_digest: state.Digest,
            input: Types.Input,
        ) !state.Digest {
            const Request = struct {
                method: state.Method,
                application: state.Name,
                profile_digest: state.Digest,
                input: Types.Input,
            };
            return operation(Request, a, .{
                .method = .submit,
                .application = try name(Types.application_id),
                .profile_digest = profile_digest,
                .input = input,
            });
        }
        pub fn submit(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            input: Types.Input,
        ) !Admission {
            try allowed(self);
            const profile_digest = try submissionProfileDigest(self, a, id);
            const request = try submitDigest(a, profile_digest, input);
            if (try replay(self, a, id, request)) |prior| return prior;
            try ensureOwnershipCapacity(self, null);
            // Reserve scheduling capacity before making acceptance durable.
            try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            try retire(self, a);
            var task_id: state.TaskId = undefined;
            try self.io.randomSecure(&task_id);
            const input_bytes = try contracts.encodeOwned(Types.Input, a, input);
            defer a.free(input_bytes);
            const controller_id: ?state.Digest = if (self.application.controller != null) blk: {
                var identity: state.Digest = undefined;
                try self.io.randomSecure(&identity);
                break :blk identity;
            } else null;
            const execution_input =
                try submissionExecutionInput(self, a, task_id, input, input_bytes);
            defer a.free(execution_input);
            const driver = try evaluator.Driver.start(self.allocator, self.program, .{
                .initial_args = execution_input,
            });
            self.active = .{ .task = task_id, .execution_revision = 0, .driver = driver };
            errdefer if (!store(self).fenced) {
                retire(self, a) catch {
                    store(self).fence();
                };
            };
            const publication = try driver.drive(a, .none, 0);
            // Retain the new receipt if durable admission fails after publish.
            errdefer store(self).fence();
            const outcome = publication.outcome;
            defer a.free(outcome);
            const checkpoint = publication.checkpoint;
            const resources = try a.alloc(state.Reference, self.profile.resources.len);
            defer a.free(resources);
            try store(self).begin();
            defer store(self).rollback();
            return persistSubmittedTask(
                self,
                a,
                id,
                request,
                task_id,
                controller_id,
                resources,
                input_bytes,
                checkpoint,
                outcome,
            );
        }
        fn submissionProfileDigest(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
        ) !state.Digest {
            var profile_digest = storage.digest(self.profile.bytes);
            const key = try operationKey(self, a, id);
            if (try store(self).savedReceipt(a, &key)) |bytes| {
                defer a.free(bytes);
                var saved = try contracts.decodeOwned(state.Receipt, a, bytes);
                defer saved.deinit();
                if (saved.value.method == .submit) {
                    var original = try self.task(a, saved.value.task);
                    defer original.deinit();
                    // The original alias is resolved only on first admission.
                    // Retrying it after a launch configuration change recovers
                    // the original receipt and cannot rebind the existing task.
                    if (same(original.value.profile_id.bytes, self.profile.id)) profile_digest =
                        original.value.profile.digest;
                }
            }

            return profile_digest;
        }
        fn submissionExecutionInput(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            input: Types.Input,
            input_bytes: []const u8,
        ) ![]u8 {
            return if (self.application.controller != null) blk: {
                if (comptime @hasDecl(
                    Types,
                    "ControllerInput",
                )) break :blk try contracts.encodeOwned(Types.ControllerInput, a, .{ .anchor = .{
                    .task = task_id,
                }, .private = .{ .initial = input } });
                return error.IncompatibleProfile;
            } else try a.dupe(u8, input_bytes);
        }
        fn submittedTask(
            self: *Self,
            task_id: state.TaskId,
            controller_id: ?state.Digest,
            resources: []const state.Reference,
            input_bytes: []const u8,
            checkpoint: []const u8,
            outcome: []const u8,
        ) !state.Task {
            return .{
                .id = task_id,
                .application_id = try name(Types.application_id),
                .input_schema_id = try name(Types.input_schema_id),
                .output_schema_id = try name(Types.output_schema_id),
                .failure_schema_id = try name(Types.failure_schema_id),
                .message_schema_id = try name(Types.message_schema_id),
                .principal = try name(self.profile.authority.principal),
                .tenant = try name(self.profile.authority.tenant),
                .profile_id = try name(self.profile.id),
                .profile = try store(self).putObject(self.profile.bytes),
                .resources = .{ .items = resources },
                .image = try store(self).putObject(self.assets.image),
                .controller = controller_id,
                .runtime_identity = self.profile.runtime_identity,
                .input = try store(self).putObject(input_bytes),
                .checkpoint = try store(self).putObject(checkpoint),
                .outcome = try store(self).putObject(outcome),
                .outcome_kind = .progressed,
                .current_occurrence = null,
                .revision = 1,
                .execution_revision = 0,
                .schedule = .queued,
                .cancellation = null,
                .cancellation_applied = false,
                .blocker = null,
                .result = null,
                .client_result = null,
                .result_artifact = null,
                .event_floor = 1,
                .event_high = 1,
                .next_message = 1,
                .messages = .{ .items = &.{} },
                .inference_attempts = 0,
                .inference_request_bytes = 0,
                .inference_output_tokens = 0,
                .evidence_bytes = 0,
            };
        }
        fn seedSubmittedController(
            self: *Self,
            _: std.mem.Allocator,
            task_id: state.TaskId,
            controller_id: state.Digest,
            image_ref: state.Reference,
            seed: discovery.SeedController,
        ) !void {
            var seed_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer seed_arena.deinit();
            const seed_allocator = seed_arena.allocator();
            var descriptor = try contracts.decodeOwned(
                contracts.controller.Descriptor,
                seed_allocator,
                seed.descriptor,
            );
            defer descriptor.deinit();
            var image = try data.program_image.decode(seed_allocator, self.assets.image);
            defer image.deinit();
            const interface = try construction.interfaceOf(seed_allocator, image.program);
            defer {
                seed_allocator.free(interface.input.bytes);
                seed_allocator.free(interface.output.bytes);
                seed_allocator.free(interface.failure.bytes);
            }
            const artifact = try workspaceStoreProgram(
                self,
                seed_allocator,
                task_id,
                seed.source,
                .source_records,
                null,
                &.{},
                .{
                    .image = .{ .bytes = self.assets.image },
                    .interface = interface,
                    .ports = .{ .items = &.{} },
                    .controller = descriptor.value,
                },
            );
            try store(self).createRecord(
                state.ControllerBinding,
                "controller_binding",
                controller_id,
                task_id,
                .{
                    .id = controller_id,
                    .task = task_id,
                    .epoch = 0,
                    .program = artifact.digest,
                    .image = image_ref,
                    .program_identity = self.application.image_identity,
                    .predecessor = null,
                },
            );
            try self.checked_workspace_programs.put(
                self.allocator,
                artifact.digest,
                store(self).integrity_epoch,
            );
        }
        fn persistSubmittedTask(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            request: state.Digest,
            task_id: state.TaskId,
            controller_id: ?state.Digest,
            resources: []state.Reference,
            input_bytes: []const u8,
            checkpoint: []const u8,
            outcome: []const u8,
        ) !Admission {
            for (self.profile.resources, resources) |bytes, *reference|
                reference.* =
                    try store(self).putObject(bytes);
            const value = try submittedTask(
                self,
                task_id,
                controller_id,
                resources,
                input_bytes,
                checkpoint,
                outcome,
            );
            // Establish the referenced task before its foreign-keyed events.
            try store(self).putTask(value, null);
            if (self.application.controller) |seed| {
                try seedSubmittedController(self, a, task_id, controller_id.?, value.image, seed);
            }
            try createCustody(self, a, task_id, null);
            try store(self).putEvent(.{
                .task = task_id,
                .seq = 1,
                .revision = 1,
                .kind = .accepted,
                .data = .{ .bytes = "{}" },
            });
            const admitted =
                try receipt(self, a, .submit, id, request, value, .accepted, null, null);
            try self.namespace.commit("task.submit");
            runnableAppendAssumeCapacity(self, task_id);
            claim(self, task_id);
            return admitted;
        }
    };
}
