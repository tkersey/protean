const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const registry = @import("../registry.zig");
const json = @import("../json.zig");
const workspace = @import("../workspace_state.zig");
const build_job = @import("../workspace_build.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const authorizeWorkspace = Access.authorizeWorkspace;
        const interpretProjection = Worker.interpretProjection;
        const occurrenceImage = Root.occurrenceImage;
        const projectionBindingAt = Worker.projectionBindingAt;
        const record = Records.record;
        const requireArchiveRecord = Occurrences.requireArchiveRecord;
        const retainedSemanticObservation = Builds.retainedSemanticObservation;
        const store = Lifecycle.store;
        const validateCompilerOutput = Builds.validateCompilerOutput;
        const validateSemanticInput = Builds.validateSemanticInput;
        const workspaceBuildReply = Builds.workspaceBuildReply;
        const workspaceCompiles = Access.workspaceCompiles;
        const workspacePrepareBuild = Builds.workspacePrepareBuild;
        const workspacePrepareSemanticBuild = Builds.workspacePrepareSemanticBuild;
        const workspaceSemanticReply = Builds.workspaceSemanticReply;
        const Occurrences = @import("archive_occurrences.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Root = @import("root_execution.zig").Operations(Types, Self);
        const Worker = @import("worker_execution.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Builds = @import("workspace_builds.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        pub fn validateCapturedProjections(
            self: *Self,
            value: state.Task,
            records: []const state.ArchiveRecord,
            mode: enum { inspect, retain },
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            try validatePreparationEvents(self, value, records);
            // Per-record scratch is backed by the service allocator so replay
            // releases it even when the enclosing request allocator is an arena.
            // A projected capture must reproduce its committed reply, replay
            // objects and usage through the same pure adapter, without acquisition.
            // Uninterpreted bytes remain private evidence, bound to the exact
            // original attempt; transfer never claims that interpretation succeeds.
            // Retained unsuccessful/rearmed attempts also need request/profile
            // coherence, even though they have no acquired response.
            for (records) |row| {
                if (row.kind == .attempt)
                    try validateCaptureAttempt(self, value, records, checked, row);
            }
            var output_tokens: u64 = 0;
            for (records) |row| {
                if (row.kind != .capture) continue;
                if (try validateCaptureProjection(
                    self,
                    value,
                    records,
                    mode == .retain,
                    row,
                )) |tokens|
                    output_tokens = try std.math.add(u64, output_tokens, tokens);
            }
            if (output_tokens != value.inference_output_tokens) return error.CorruptState;
        }
        fn validateCaptureAttempt(
            self: *Self,
            value: state.Task,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
            row: state.ArchiveRecord,
        ) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const temporary = arena.allocator();
            var attempt =
                try record(self, state.Attempt, temporary, "attempt", row.id, value.id);
            defer attempt.deinit();
            if (!std.meta.eql(attempt.value.id, row.id) or
                !std.meta.eql(attempt.value.task, value.id)) return error.InvalidArchive;
            try validatePreparationAttempt(self, temporary, value, attempt.value);
            try requireArchiveRecord(records, .occurrence, attempt.value.occurrence);
            var saved = try record(
                self,
                occurrence.Occurrence,
                temporary,
                "occurrence",
                attempt.value.occurrence,
                value.id,
            );
            defer saved.deinit();
            const encoded =
                try store(self).object(temporary, attempt.value.request, null);
            var request = try data.invocation.decode(data.invocation.Request, temporary, encoded);
            defer request.deinit();
            const entry = try self.handlers.resolve(
                request.value,
                try occurrenceImage(self, temporary, value, saved.value),
            );
            var validation: CaptureAttemptValidation = .{
                .service = self,
                .a = temporary,
                .value = value,
                .records = records,
                .checked = checked,
                .attempt = attempt.value,
                .saved = saved.value,
                .request = request.value,
                .entry = entry,
            };
            if (attempt.value.operation == .workspace_build) return validation.workspaceBuild();
            try validation.leaf();
        }
        const CaptureAttemptValidation = captureAttemptValidationType();
        fn captureAttemptValidationType() type {
            return struct {
                service: *Self,
                a: std.mem.Allocator,
                value: state.Task,
                records: []const state.ArchiveRecord,
                checked: *Snapshots.SnapshotValidation,
                attempt: state.Attempt,
                saved: occurrence.Occurrence,
                request: data.invocation.Request,
                entry: registry.Entry,
                fn requireWorkspaceBuild(validation: *@This()) !void {
                    if (validation.entry.declaration.kind != .workspace or
                        validation.saved.work != null or
                        validation.saved.residual != null or
                        validation.attempt.inference or
                        validation.attempt.prepared == null or
                        validation.attempt.controller_context != null or
                        !same(&validation.request.request_identity, &validation.saved.request) or
                        !std.meta.eql(
                            validation.attempt.request,
                            validation.saved.request_object,
                        ) or
                        !std.meta.eql(validation.attempt.profile, validation.value.profile) or
                        !same(
                            validation.attempt.capability.bytes,
                            validation.entry.declaration.identity,
                        )) return error.InvalidArchive;
                }
                fn workspaceBuild(validation: *@This()) !void {
                    try validation.requireWorkspaceBuild();
                    const authorized_bytes = try authorizeWorkspace(
                        validation.service,
                        validation.a,
                        validation.value,
                        validation.entry,
                        validation.request.binding.payload,
                    );
                    var authorized = try contracts.decodeOwned(
                        workspace.Authorized,
                        validation.a,
                        authorized_bytes,
                    );
                    defer authorized.deinit();
                    if (!workspaceCompiles(authorized.value.command))
                        return error.InvalidArchive;
                    const retained_input = try store(validation.service).object(
                        validation.a,
                        validation.attempt.prepared.?,
                        null,
                    );
                    var job =
                        try contracts.decodeOwned(build_job.Input, validation.a, retained_input);
                    defer job.deinit();
                    if (job.value != .program) {
                        try validateSemanticInput(
                            validation.service,
                            validation.a,
                            validation.value,
                            authorized.value.command.program,
                            job.value,
                            validation.records,
                            validation.attempt.controller_read,
                            validation.checked,
                        );
                    }
                    if (job.value == .program and validation.attempt.controller_read != null)
                        return error.InvalidArchive;
                    const frozen = if (job.value == .program)
                        try workspacePrepareBuild(
                            validation.service,
                            validation.a,
                            validation.value,
                            authorized.value,
                        )
                    else
                        try workspacePrepareSemanticBuild(
                            validation.service,
                            validation.a,
                            validation.value,
                            authorized.value.command.program,
                            if (job.value == .derive) job.value.derive.basis else null,
                        );
                    if (!same(
                        frozen,
                        try store(validation.service).object(
                            validation.a,
                            validation.attempt.prepared.?,
                            null,
                        ),
                    )) return error.InvalidArchive;
                }
                fn leaf(validation: *@This()) !void {
                    if (validation.attempt.controller_read != null or
                        validation.entry.declaration.kind != .leaf or
                        !same(&validation.request.request_identity, &validation.saved.request) or
                        !std.meta.eql(
                            validation.attempt.request,
                            validation.saved.request_object,
                        ) or
                        !std.meta.eql(validation.attempt.profile, validation.value.profile) or
                        !same(
                            validation.attempt.capability.bytes,
                            validation.entry.declaration.identity,
                        ) or
                        validation.attempt.inference != validation.entry.declaration.inference or
                        (validation.attempt.prepared != null) !=
                            (validation.entry.declaration.capture != null))
                        return error.InvalidArchive;
                    var attempt_binding = try projectionBindingAt(
                        validation.service,
                        validation.a,
                        validation.value,
                        validation.saved,
                        validation.attempt.controller_context,
                    );
                    attempt_binding = try Worker.withPreparationCut(
                        validation.service,
                        validation.a,
                        validation.value,
                        attempt_binding,
                        validation.attempt.preparation_cut,
                    );
                    if (validation.entry.declaration.capture) |adapter| {
                        const prepared = try store(validation.service).object(
                            validation.a,
                            validation.attempt.prepared.?,
                            null,
                        );
                        var replay_arena =
                            std.heap.ArenaAllocator.init(validation.service.allocator);
                        defer replay_arena.deinit();
                        const replayed = try store(validation.service).project(
                            []u8,
                            replay_arena.allocator(),
                            validation.service.handlers,
                            attempt_binding,
                            struct {
                                adapter: registry.CaptureAdapter,
                                payload: []const u8,
                                pub fn run(
                                    this: @This(),
                                    context: registry.ProjectionContext,
                                ) ![]u8 {
                                    return this.adapter.prepare(context, this.payload);
                                }
                            }{ .adapter = adapter, .payload = try validation.entry.payload(
                                validation.a,
                                validation.request.binding.payload,
                            ) },
                        );
                        if (!same(prepared, replayed)) return error.CorruptState;
                    }
                }
            };
        }
        fn preparationReference(a: std.mem.Allocator, attempt: state.Attempt) !state.Reference {
            const bytes = try contracts.encodeOwned(state.Attempt, a, attempt);
            defer a.free(bytes);
            return .{ .digest = storage.digest(bytes), .bytes = bytes.len };
        }

        fn validatePreparationAttempt(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            attempt: state.Attempt,
        ) !void {
            const required = attempt.operation == .environment and attempt.prepared != null;
            if (required != (attempt.preparation_cut != null)) return error.InvalidArchive;
            const cut = attempt.preparation_cut orelse return;
            const sequence = std.math.add(u64, cut, 1) catch return error.InvalidArchive;
            if (sequence > parent.event_high) return error.InvalidArchive;
            var query = try store(self).database.prepare(
                "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body " ++
                    "WHERE e.task=? AND e.seq=?",
                &.{ .{ .blob = &parent.id }, .{
                    .integer = std.math.cast(i64, sequence) orelse return error.InvalidArchive,
                } },
            );
            defer query.deinit();
            if (try query.step() != .row) return error.InvalidArchive;
            var event = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
            defer event.deinit();
            if (event.value.kind != .preparation or event.value.seq != sequence or
                !std.meta.eql(event.value.task, parent.id) or
                !std.meta.eql(
                    event.value.preparation_attempt,
                    @as(?state.Reference, try preparationReference(a, attempt)),
                ))
                return error.InvalidArchive;
        }

        fn validatePreparationEvents(
            self: *Self,
            parent: state.Task,
            records: []const state.ArchiveRecord,
        ) !void {
            var query = try store(self).database.prepare(
                "SELECT e.seq,o.body FROM events e JOIN objects o ON o.digest=e.body " ++
                    "WHERE e.task=? ORDER BY e.seq",
                &.{.{ .blob = &parent.id }},
            );
            defer query.deinit();
            while (try query.step() == .row) {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const event = try contracts.decodeOwned(state.Event, a, try query.bytes(1));
                const value = event.value;
                if ((value.kind == .preparation) != (value.preparation_attempt != null))
                    return error.InvalidArchive;
                const reference = value.preparation_attempt orelse continue;
                const sequence = std.math.cast(u64, try query.integer(0)) orelse
                    return error.InvalidArchive;
                if (sequence == 0 or value.seq != sequence or sequence > parent.event_high or
                    !std.meta.eql(value.task, parent.id)) return error.InvalidArchive;
                const bytes = try store(self).object(a, reference, null);
                const attempt = try contracts.decodeOwned(state.Attempt, a, bytes);
                if (!std.meta.eql(attempt.value.task, parent.id) or
                    attempt.value.operation != .environment or attempt.value.prepared == null or
                    attempt.value.preparation_cut != sequence - 1 or
                    !std.meta.eql(reference, try preparationReference(a, attempt.value)))
                    return error.InvalidArchive;
                try validatePreparationData(a, value, attempt.value);
                try requirePreparationRecord(records, attempt.value.id, reference);
            }
        }

        fn validatePreparationData(
            a: std.mem.Allocator,
            event: state.Event,
            attempt: state.Attempt,
        ) !void {
            var data_value = try json.parse(a, event.data.bytes, .{});
            defer data_value.deinit();
            inline for (.{ .{ "occurrence_id", "occurrence" }, .{ "attempt_id", "id" } }) |field| {
                const text = try json.text(json.get(data_value.value, field[0]) orelse
                    return error.InvalidArchive);
                var id: state.Digest = undefined;
                if (text.len != id.len * 2) return error.InvalidArchive;
                _ = std.fmt.hexToBytes(&id, text) catch return error.InvalidArchive;
                if (!std.meta.eql(id, @field(attempt, field[1]))) return error.InvalidArchive;
            }
        }

        fn requirePreparationRecord(
            records: []const state.ArchiveRecord,
            id: state.Digest,
            reference: state.Reference,
        ) !void {
            for (records) |row| {
                if (row.kind != .attempt or !std.meta.eql(row.id, id)) continue;
                if (!std.meta.eql(row.body, reference)) return error.InvalidArchive;
                return;
            }
            return error.InvalidArchive;
        }
        fn validateCaptureProjection(
            self: *Self,
            value: state.Task,
            records: []const state.ArchiveRecord,
            retain: bool,
            row: state.ArchiveRecord,
        ) !?u64 {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const temporary = arena.allocator();
            var raw =
                try record(self, state.Capture, temporary, "capture", row.id, value.id);
            defer raw.deinit();
            const capture_value = raw.value;
            if (!same(&capture_value.attempt, &row.id) or
                (capture_value.disposition == .complete) != (capture_value.response != null))
                return error.CorruptState;
            try requireArchiveRecord(records, .attempt, row.id);
            var attempt =
                try record(self, state.Attempt, temporary, "attempt", row.id, value.id);
            defer attempt.deinit();
            var saved = try record(
                self,
                occurrence.Occurrence,
                temporary,
                "occurrence",
                capture_value.occurrence,
                value.id,
            );
            defer saved.deinit();
            var validation: CaptureProjectionValidation = .{
                .service = self,
                .a = temporary,
                .value = value,
                .retain = retain,
                .row = row,
                .capture = capture_value,
                .attempt = attempt.value,
                .saved = saved.value,
            };
            return validation.validate();
        }
        const CaptureProjectionValidation = captureProjectionValidationType();
        fn captureProjectionValidationType() type {
            return struct {
                service: *Self,
                a: std.mem.Allocator,
                value: state.Task,
                retain: bool,
                row: state.ArchiveRecord,
                capture: state.Capture,
                attempt: state.Attempt,
                saved: occurrence.Occurrence,
                fn validate(validation: *@This()) !?u64 {
                    if (validation.attempt.prepared == null or
                        !same(&validation.attempt.occurrence, &validation.capture.occurrence) or
                        !std.meta.eql(validation.attempt.profile, validation.value.profile) or
                        !std.meta.eql(
                            validation.attempt.prepared.?,
                            validation.capture.request,
                        )) return error.CorruptState;
                    if (validation.attempt.operation == .workspace_build and
                        validation.capture.response != null)
                    {
                        try validateWorkspaceBuildCapture(
                            validation.service,
                            validation.a,
                            validation.value,
                            validation.saved,
                            validation.attempt,
                            validation.capture,
                        );
                        if (validation.capture.projection != null) return null;
                    }
                    const projection = validation.capture.projection orelse {
                        const original_attempt = switch (validation.saved.state) {
                            .captured => |pending| if (validation.capture.disposition ==
                                .complete) pending.id else return error.CorruptState,
                            .unknown => |pending| if (validation.capture.disposition ==
                                .unknown) pending.id else return error.CorruptState,
                            .not_sent => |pending| if (validation.capture.disposition ==
                                .definitely_not_sent) pending.id else return error.CorruptState,
                            else => return error.CorruptState,
                        };
                        if (!same(&original_attempt, &validation.row.id)) return error.CorruptState;
                        return null;
                    };
                    return validation.project(projection);
                }
                fn project(validation: *@This(), projection: anytype) !?u64 {
                    if (validation.capture.disposition != .complete) return error.CorruptState;
                    const acquired = switch (validation.saved.state) {
                        .settled_reply => |reply| reply,
                        .admitted => |admitted| if (admitted ==
                            .reply) admitted.reply else return error.CorruptState,
                        else => return error.UnsettledOccurrence,
                    };
                    if (!same(&acquired.attempt, &validation.row.id) or
                        !same(&acquired.reply, &projection.reply.digest)) return error.CorruptState;
                    const encoded = try store(validation.service).object(
                        validation.a,
                        validation.attempt.request,
                        null,
                    );
                    var request =
                        try data.invocation.decode(data.invocation.Request, validation.a, encoded);
                    defer request.deinit();
                    if (!same(&request.value.request_identity, &validation.saved.request))
                        return error.CorruptState;
                    const entry = try validation.service.handlers.resolve(
                        request.value,
                        try occurrenceImage(
                            validation.service,
                            validation.a,
                            validation.value,
                            validation.saved,
                        ),
                    );
                    if (!same(validation.attempt.capability.bytes, entry.declaration.identity) or
                        validation.attempt.inference != entry.declaration.inference)
                        return error.IncompatibleProfile;
                    const adapter = entry.declaration.capture orelse
                        return error.IncompatibleProfile;
                    const rendered = try store(validation.service).object(
                        validation.a,
                        validation.capture.request,
                        null,
                    );
                    const response = try store(validation.service).object(
                        validation.a,
                        validation.capture.response.?,
                        null,
                    );
                    var interpretation_arena =
                        std.heap.ArenaAllocator.init(validation.service.allocator);
                    defer interpretation_arena.deinit();
                    const result = try interpretProjection(
                        validation.service,
                        interpretation_arena.allocator(),
                        validation.value,
                        validation.saved,
                        adapter,
                        try entry.payload(validation.a, request.value.binding.payload),
                        rendered,
                        response,
                    );
                    return validation.verifyProjection(projection, entry, adapter, result);
                }

                fn verifyProjection(
                    validation: *@This(),
                    projection: anytype,
                    entry: registry.Entry,
                    adapter: registry.CaptureAdapter,
                    result: registry.Projection,
                ) !?u64 {
                    if (result.objects.len != projection.objects.items.len or
                        result.output_tokens != projection.output_tokens)
                        return error.CorruptState;
                    for (result.objects, projection.objects.items) |object, reference| {
                        if (object.len != reference.bytes or !same(
                            &storage.digest(object),
                            &reference.digest,
                        )) return error.CorruptState;
                    }
                    if (validation.retain) try store(
                        validation.service,
                    ).retainProjection(adapter.dependencies, result.objects);
                    var schema = try data.schema.decode(validation.a, entry.resume_schema);
                    defer schema.deinit();
                    try data.schema.validateValue(validation.a, schema.descriptor, result.reply);
                    const bound = try data.invocation.encodeOwned(
                        data.invocation.Result,
                        validation.a,
                        .{
                            .request_identity = validation.saved.request,
                            .value = result.reply,
                        },
                    );
                    if (!same(
                        bound,
                        try store(validation.service).object(validation.a, projection.reply, null),
                    )) return error.CorruptState;
                    return if (entry.declaration.inference) result.output_tokens else null;
                }
            };
        }
        fn validateWorkspaceBuildCapture(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            pending: occurrence.Occurrence,
            attempt: state.Attempt,
            raw: state.Capture,
        ) !void {
            if (attempt.operation != .workspace_build or raw.disposition != .complete or
                raw.response == null or raw.reconciliation != null)
                return error.InvalidArchive;
            const prepared = try store(self).object(a, raw.request, null);
            const response = try store(self).object(a, raw.response.?, null);
            try validateCompilerOutput(self, parent.id, prepared, response);
            const projection = raw.projection orelse return;
            if (projection.objects.items.len != 0 or projection.output_tokens != null)
                return error.InvalidArchive;
            const acquired = switch (pending.state) {
                .settled_reply => |reply| reply,
                .admitted => |admitted| if (admitted ==
                    .reply) admitted.reply else return error.InvalidArchive,
                else => return error.InvalidArchive,
            };
            if (!std.meta.eql(acquired.attempt, attempt.id) or
                !std.meta.eql(acquired.reply, projection.reply.digest)) return error.InvalidArchive;
            var output = try contracts.decodeOwned(build_job.Output, a, response);
            defer output.deinit();
            const bound_bytes = try store(self).object(a, projection.reply, null);
            var bound = try data.invocation.decode(data.invocation.Result, a, bound_bytes);
            defer bound.deinit();
            var reply = try contracts.decodeOwned(wc.Reply, a, bound.value.value);
            defer reply.deinit();
            var frozen_input = try contracts.decodeOwned(build_job.Input, a, prepared);
            defer frozen_input.deinit();
            if (frozen_input.value != .program) {
                try validateSemanticBuildCapture(
                    self,
                    a,
                    parent.id,
                    frozen_input.value,
                    output.value,
                    raw.response.?,
                    bound.value.value,
                );
                return;
            }
            const program = try validateBuildProjectionProgram(
                self,
                a,
                parent.id,
                prepared,
                output.value,
                reply.value,
            );
            const replayed = try workspaceBuildReply(self, a, program, output.value);
            const payload = try contracts.encodeOwned(wc.Reply, a, replayed);
            const result = try data.invocation.encodeOwned(data.invocation.Result, a, .{
                .request_identity = pending.request,
                .value = payload,
            });
            if (!same(result, bound_bytes)) return error.InvalidArchive;
        }
        fn validateSemanticBuildCapture(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            input: build_job.Input,
            output: build_job.Output,
            response: state.Reference,
            expected: []const u8,
        ) !void {
            const observed =
                try retainedSemanticObservation(self, a, task_id, input, output, response);
            const expected_reply = try workspaceSemanticReply(self, a, task_id, observed);
            const encoded = try contracts.encodeOwned(wc.Reply, a, expected_reply);
            defer a.free(encoded);
            if (!same(encoded, expected)) return error.InvalidArchive;
        }
        fn validateBuildProjectionProgram(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            prepared: []const u8,
            output: build_job.Output,
            reply: wc.Reply,
        ) !?state.Reference {
            var program: ?contracts.Decoded(workspace.Program) = null;
            defer if (program) |*item| item.deinit();
            if (output == .compiled) {
                const ref = reply.program orelse return error.InvalidArchive;
                program =
                    try self.workspaceProgram(a, task_id, try wp.identity(ref, .program));
                const artifact = program.?.value.description;
                var input = try contracts.decodeOwned(build_job.Input, a, prepared);
                defer input.deinit();
                if (input.value != .program) return error.InvalidArchive;
                const built = input.value.program;
                if (!std.meta.eql(artifact.source, state.Reference{
                    .digest = storage.digest(built.source.bytes),
                    .bytes = built.source.bytes.len,
                }) or
                    @backingInt(artifact.source_kind) != @backingInt(built.kind) or
                    !std.meta.eql(artifact.image, state.Reference{
                        .digest = storage.digest(output.compiled.image.bytes),
                        .bytes = output.compiled.image.bytes.len,
                    })) return error.InvalidArchive;
                const exposures = try contracts.encodeOwned(
                    contracts.Vector(wc.Exposure, null),
                    a,
                    built.exposures,
                );
                if (!same(
                    exposures,
                    try contracts.encodeOwned(
                        contracts.Vector(wc.Exposure, null),
                        a,
                        artifact.exposures,
                    ),
                )) return error.InvalidArchive;
                const catalog: ?state.Reference = if (built.catalog) |bytes| .{
                    .digest = storage.digest(bytes.bytes),
                    .bytes = bytes.bytes.len,
                } else null;
                if (!std.meta.eql(catalog, artifact.catalog)) return error.InvalidArchive;
            } else if (reply.program != null) return error.InvalidArchive;
            return if (program) |item| item.value.artifact else null;
        }
    };
}
