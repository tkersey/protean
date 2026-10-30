const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const registry = @import("../registry.zig");
const workspace = @import("../workspace_state.zig");
const instrument = @import("../workspace_instrument.zig");
const wp = @import("../workspace_projection.zig");
const task_types = @import("types.zig");
const Work = task_types.Work;
const answerDigest = task_types.answerDigest;
const cancelDigest = task_types.cancelDigest;
const operation = task_types.operation;
const reconcileDigest = task_types.reconcileDigest;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const allowed = Lifecycle.allowed;
        const controllerInternal = Context.controllerInternal;
        const controllerStoredReply = ControllerProtocol.controllerStoredReply;
        const controllerTrialAllowsLive = Execution.controllerTrialAllowsLive;
        const controllerTrialReply = Execution.controllerTrialReply;
        const messageDigest = messages_ops.messageDigest;
        const occurrenceImage = Root.occurrenceImage;
        const operationKey = Records.operationKey;
        const rootRouteImage = Controller.rootRouteImage;
        const store = Lifecycle.store;
        const submitDigest = Admission.submitDigest;
        const validateWorkspaceReply = Replay.validateWorkspaceReply;
        const workspaceProgram = Programs.workspaceProgram;
        const workspaceValueReference = Contexts.workspaceValueReference;
        const workspaceWork = Programs.workspaceWork;
        const Admission = @import("admission.zig").Operations(Types, Self);
        const Context = @import("controller_context.zig").Operations(Types, Self);
        const ControllerProtocol = @import("controller_protocol.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const messages_ops = @import("messages.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Root = @import("root_execution.zig").Operations(Types, Self);
        const Contexts = @import("workspace_contexts.zig").Operations(Types, Self);
        const Execution = @import("workspace_execution.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Replay = @import("workspace_replay.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        pub fn archiveAccess(self: *Self) !void {
            try allowed(self);
            if (self.work != null) return error.UnsettledOccurrence;
        }
        pub fn requireArchiveRecord(
            records: []const state.ArchiveRecord,
            kind: state.RecordKind,
            id: state.Digest,
        ) !void {
            for (records) |row| if (row.kind == kind and same(&row.id, &id)) return;
            return error.InvalidArchive;
        }
        fn validateInboxReply(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            saved: occurrence.Occurrence,
            bytes: []const u8,
        ) !?state.Digest {
            // Both directions of the inbox/message relationship are checked. An
            // empty reply has no message; a nonempty reply names exactly the saved
            // payload and its acquired/consumed boundary.
            var decoded = try contracts.decodeOwned(contracts.InboxReply(Types.Message), a, bytes);
            defer decoded.deinit();
            if (decoded.value == .empty) return null;
            const input = decoded.value.message;
            var id: state.Digest = undefined;
            if (input.id.bytes.len != 64) return error.InvalidArchive;
            _ = std.fmt.hexToBytes(&id, input.id.bytes) catch return error.InvalidArchive;
            var message_value = try Records.record(self, state.Message, a, "message", id, task_id);
            defer message_value.deinit();
            const item = message_value.value;
            const expected: state.MessageDisposition = switch (saved.state) {
                .settled_reply => .acquired,
                .admitted => |admitted| if (admitted ==
                    .reply) .consumed else return error.InvalidArchive,
                else => return error.InvalidArchive,
            };
            if (item.disposition != expected or item.occurrence == null or
                !same(&item.occurrence.?, &saved.id)) return error.InvalidArchive;
            const encoded = try contracts.encodeOwned(Types.Message, a, input.value);
            defer a.free(encoded);
            if (item.value.bytes != encoded.len or
                !same(&item.value.digest, &storage.digest(encoded))) return error.InvalidArchive;
            return id;
        }
        pub fn validateArchiveAdmissions(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            index: state.Archive,
        ) !void {
            // The operation index preserves original identity even when a repeated
            // answer also has aliases. Messages, receipts and inbox history are one
            // admitted relationship, not independently trustworthy rows.
            var admission: ArchiveAdmissions = .{
                .service = self,
                .a = a,
                .value = value,
                .index = index,
                .receipts = .init(a),
                .ordinals = .init(a),
            };
            defer admission.receipts.deinit();
            defer admission.ordinals.deinit();
            for (index.operations.items) |row| try admission.operation(row);
            if (!admission.submitted) return error.InvalidArchive;
            if (value.cancellation) |reason| if (admission.first_cancel) |admitted| {
                const expected = try cancelDigest(a, value.id, reason);
                if (!same(&admitted.request, &expected)) return error.InvalidArchive;
            };
            for (index.records.items) |row| try admission.message(row);
            if (value.next_message != admission.count + 1 or
                admission.receipts.count() != admission.count) return error.InvalidArchive;
        }
        const ArchiveAdmissions = archiveAdmissionsType();
        fn archiveAdmissionsType() type {
            return struct {
                service: *Self,
                a: std.mem.Allocator,
                value: state.Task,
                index: state.Archive,
                receipts: std.AutoHashMap(state.Digest, state.Digest),
                ordinals: std.AutoHashMap(u64, void),
                submitted: bool = false,
                first_cancel: ?struct { revision: u64, request: state.Digest } = null,
                count: u64 = 0,
                fn operation(admission: *@This(), row: state.ArchiveOperation) !void {
                    var arena = std.heap.ArenaAllocator.init(admission.service.allocator);
                    defer arena.deinit();
                    const temporary = arena.allocator();
                    const bytes =
                        try store(admission.service).object(temporary, row.body, null);
                    var decoded = try contracts.decodeOwned(state.Receipt, temporary, bytes);
                    defer decoded.deinit();
                    const receipt_value = decoded.value;
                    if (receipt_value.method == .cancel and (admission.first_cancel == null or
                        receipt_value.revision < admission.first_cancel.?.revision))
                    {
                        admission.first_cancel = .{
                            .revision = receipt_value.revision,
                            .request = receipt_value.request_digest,
                        };
                    }
                    try admission.receiptIdentity(temporary, row, bytes, receipt_value);
                    if (receipt_value.method == .submit) {
                        if (admission.submitted or
                            receipt_value.revision != 1) return error.InvalidArchive;
                        admission.submitted = true;
                        const input_bytes = try store(admission.service).object(
                            temporary,
                            admission.value.input,
                            null,
                        );
                        var input = try contracts.decodeOwned(Types.Input, temporary, input_bytes);
                        defer input.deinit();
                        const expected_digest = try submitDigest(
                            temporary,
                            admission.value.profile.digest,
                            input.value,
                        );
                        if (!same(&expected_digest, &receipt_value.request_digest))
                            return error.InvalidArchive;
                    }
                    if (receipt_value.method == .message) {
                        const id = receipt_value.message.?;
                        const found = try admission.receipts.getOrPut(id);
                        if (found.found_existing) return error.InvalidArchive;
                        found.value_ptr.* = receipt_value.request_digest;
                    }
                    if (receipt_value.method == .reconcile)
                        try admission.reconcile(temporary, receipt_value);
                }
                fn receiptIdentity(
                    admission: *@This(),
                    temporary: std.mem.Allocator,
                    row: state.ArchiveOperation,
                    bytes: []const u8,
                    receipt_value: state.Receipt,
                ) !void {
                    const primary = try operationKey(
                        admission.service,
                        temporary,
                        receipt_value.client_operation_id.bytes,
                    );
                    const original = (try store(admission.service).savedReceipt(
                        temporary,
                        &primary,
                    )) orelse return error.InvalidArchive;
                    if (!same(bytes, original) or (!same(row.key.bytes, &primary) and
                        receipt_value.method != .respond)) return error.InvalidArchive;
                    const expected: state.Disposition = switch (receipt_value.method) {
                        .submit => .accepted,
                        .message => .queued,
                        .respond => .answer_acquired,
                        .cancel => .cancellation_requested,
                        .@"resume" => .resumed,
                        .import_checkpoint => .imported,
                        .reconcile => .reconciled,
                        .workspace => .accepted,
                        .adopt => .accepted,
                    };
                    if (receipt_value.disposition != expected or
                        (receipt_value.message != null) != (receipt_value.method == .message) or
                        (receipt_value.question != null) != (receipt_value.method == .respond))
                        return error.InvalidArchive;
                }
                fn reconcile(
                    admission: *@This(),
                    temporary: std.mem.Allocator,
                    receipt_value: state.Receipt,
                ) !void {
                    const id = receipt_value.reconciliation orelse return error.InvalidArchive;
                    try requireArchiveRecord(admission.index.records.items, .reconciliation, id);
                    var recovery = try Records.record(
                        admission.service,
                        state.Reconciliation,
                        temporary,
                        "reconciliation",
                        id,
                        admission.value.id,
                    );
                    defer recovery.deinit();
                    if (recovery.value.admission_revision == 0) return error.InvalidArchive;
                    const expected_digest = try reconcileDigest(
                        temporary,
                        admission.value.id,
                        recovery.value.admission_revision - 1,
                        recovery.value.occurrence,
                        recovery.value.attempt,
                        recovery.value.selection,
                    );
                    if (!same(&expected_digest, &receipt_value.request_digest))
                        return error.InvalidArchive;
                }
                fn message(admission: *@This(), row: state.ArchiveRecord) !void {
                    if (row.kind != .message) return;
                    var arena = std.heap.ArenaAllocator.init(admission.service.allocator);
                    defer arena.deinit();
                    const temporary = arena.allocator();
                    var decoded = try Records.record(
                        admission.service,
                        state.Message,
                        temporary,
                        "message",
                        row.id,
                        admission.value.id,
                    );
                    defer decoded.deinit();
                    const item = decoded.value;
                    if (!same(item.schema_id.bytes, Types.message_schema_id) or item.ordinal == 0 or
                        item.ordinal >= admission.value.next_message)
                        return error.InvalidArchive;
                    const ordinal = try admission.ordinals.getOrPut(item.ordinal);
                    if (ordinal.found_existing) return error.InvalidArchive;
                    admission.count += 1;
                    const bytes =
                        try store(admission.service).object(temporary, item.value, null);
                    var payload =
                        contracts.decodeOwned(Types.Message, temporary, bytes) catch |err| {
                            return if (err == error.OutOfMemory) err else error.InvalidArchive;
                        };
                    defer payload.deinit();
                    const receipt_digest =
                        admission.receipts.get(item.id) orelse return error.InvalidArchive;
                    if (!same(
                        &receipt_digest,
                        &try messageDigest(temporary, admission.value.id, payload.value),
                    )) return error.InvalidArchive;
                    try admission.disposition(temporary, item);
                }
                fn disposition(
                    admission: *@This(),
                    temporary: std.mem.Allocator,
                    item: state.Message,
                ) !void {
                    switch (item.disposition) {
                        .queued, .not_consumed => {
                            if (item.occurrence != null or
                                (item.disposition == .not_consumed and !admission.value.terminal()))
                                return error.InvalidArchive;
                        },
                        .acquired, .consumed => {
                            try admission.validateAcquired(temporary, item);
                        },
                    }
                }
                fn validateAcquired(
                    admission: *@This(),
                    temporary: std.mem.Allocator,
                    item: state.Message,
                ) !void {
                    const occurrence_id = item.occurrence orelse return error.InvalidArchive;
                    try requireArchiveRecord(
                        admission.index.records.items,
                        .occurrence,
                        occurrence_id,
                    );
                    var saved = try Records.record(
                        admission.service,
                        occurrence.Occurrence,
                        temporary,
                        "occurrence",
                        occurrence_id,
                        admission.value.id,
                    );
                    defer saved.deinit();
                    const acquired = switch (saved.value.state) {
                        .settled_reply => |reply| reply,
                        .admitted => |admitted| if (admitted ==
                            .reply) admitted.reply else return error.InvalidArchive,
                        else => return error.InvalidArchive,
                    };
                    const request_bytes = try store(admission.service).object(
                        temporary,
                        saved.value.request_object,
                        null,
                    );
                    var request = try data.invocation.decode(
                        data.invocation.Request,
                        temporary,
                        request_bytes,
                    );
                    defer request.deinit();
                    const entry = try admission.service.handlers.resolve(
                        request.value,
                        try occurrenceImage(
                            admission.service,
                            temporary,
                            admission.value,
                            saved.value,
                        ),
                    );
                    if (entry.declaration.kind != .inbox) return error.InvalidArchive;
                    const bound = try store(admission.service).acquiredObject(
                        temporary,
                        acquired.reply,
                        null,
                    );
                    var reply =
                        try data.invocation.decode(data.invocation.Result, temporary, bound);
                    defer reply.deinit();
                    const input_id = (try validateInboxReply(
                        admission.service,
                        temporary,
                        admission.value.id,
                        saved.value,
                        reply.value.value,
                    )) orelse return error.InvalidArchive;
                    if (!same(&input_id, &item.id)) return error.InvalidArchive;
                }
            };
        }
        fn validateWorkspacePortOccurrence(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            pending: occurrence.Occurrence,
            reference: state.Reference,
            request: data.invocation.Request,
            records: []const state.ArchiveRecord,
        ) !void {
            // The retained request determines which acquisition evidence must
            // exist. Validating only supplied attempts/questions misses omissions.
            var validation: PortOccurrenceValidation = .{
                .service = self,
                .a = a,
                .task_id = task_id,
                .pending = pending,
                .reference = reference,
                .request = request,
                .records = records,
            };
            try validation.run();
        }
        const PortOccurrenceValidation = portOccurrenceValidationType();
        fn portOccurrenceValidationType() type {
            return struct {
                service: *Self,
                a: std.mem.Allocator,
                task_id: state.TaskId,
                pending: occurrence.Occurrence,
                reference: state.Reference,
                request: data.invocation.Request,
                records: []const state.ArchiveRecord,
                fn run(validation: *@This()) !void {
                    const bytes = try store(validation.service).object(
                        validation.a,
                        validation.reference,
                        null,
                    );
                    var decoded = try contracts.decodeOwned(workspace.Port, validation.a, bytes);
                    defer decoded.deinit();
                    const port = decoded.value;
                    try validation.record(port);
                    var work = try workspaceWork(
                        validation.service,
                        validation.a,
                        validation.task_id,
                        port.work,
                    );
                    defer work.deinit();
                    try validation.validateProgram(port, work.value);
                    var payload_schema = try data.schema.decode(
                        validation.a,
                        validation.request.binding.payload_schema,
                    );
                    defer payload_schema.deinit();
                    try data.schema.validateValue(
                        validation.a,
                        payload_schema.descriptor,
                        validation.request.binding.payload,
                    );
                    const acquired: ?occurrence.Acquired = switch (validation.pending.state) {
                        .ready => null,
                        .settled_reply => |reply| reply,
                        .admitted => |admitted| if (admitted ==
                            .reply) admitted.reply else if (admitted.cancelled ==
                            null) null else return error.InvalidArchive,
                        else => return error.InvalidArchive,
                    };
                    if (acquired) |reply| try validation.validateReply(port, work.value, reply);
                }
                fn record(validation: *@This(), port: workspace.Port) !void {
                    try requireArchiveRecord(validation.records, .workspace_port, port.id);
                    const record_bytes = (try store(validation.service).recordBytes(
                        validation.a,
                        "workspace_port",
                        port.id,
                        validation.task_id,
                    )) orelse return error.InvalidArchive;
                    const canonical: state.Reference = .{
                        .digest = storage.digest(record_bytes),
                        .bytes = record_bytes.len,
                    };
                    if (!std.meta.eql(canonical, validation.reference) or
                        !std.meta.eql(port.task, validation.task_id) or
                        !std.meta.eql(@as(?state.Digest, port.work), validation.pending.work) or
                        !std.meta.eql(port.occurrence, validation.pending.id) or
                        !std.meta.eql(port.request_identity, validation.pending.request) or
                        !std.meta.eql(port.request, validation.pending.request_object) or
                        port.generation == 0) return error.InvalidArchive;
                }
                fn validateProgram(
                    validation: *@This(),
                    port: workspace.Port,
                    work: workspace.Work,
                ) !void {
                    var program = try workspaceProgram(
                        validation.service,
                        validation.a,
                        validation.task_id,
                        work.program,
                    );
                    defer program.deinit();
                    if (!std.meta.eql(port.program, program.value.artifact) or
                        port.generation > work.port_generation) return error.InvalidArchive;
                    var matched = false;
                    for (program.value.description.ports.items) |candidate| {
                        if (!same(candidate.identity.bytes, port.interface.identity.bytes))
                            continue;
                        if (candidate.class != port.interface.class) return error.InvalidArchive;
                        inline for (.{
                            "argument",
                            "observation",
                            "payload",
                            "command",
                        }) |field| if (!std.meta.eql(
                            @field(candidate, field),
                            @field(port.interface, field),
                        )) return error.InvalidArchive;
                        matched = true;
                    }
                    if (!matched or !same(
                        port.interface.identity.bytes,
                        validation.request.binding.semantic_identity,
                    ) or
                        !std.meta.eql(port.interface.payload, state.Reference{
                            .digest = storage.digest(validation.request.binding.payload_schema),
                            .bytes = validation.request.binding.payload_schema.len,
                        }) or
                        !std.meta.eql(port.interface.command, state.Reference{
                            .digest = storage.digest(validation.request.binding.resume_schema),
                            .bytes = validation.request.binding.resume_schema.len,
                        }) or
                        !std.meta.eql(port.payload, state.Reference{
                            .digest = storage.digest(validation.request.binding.payload),
                            .bytes = validation.request.binding.payload.len,
                        })) return error.InvalidArchive;
                }
                fn validateReply(
                    validation: *@This(),
                    port: workspace.Port,
                    work: workspace.Work,
                    reply: occurrence.Acquired,
                ) !void {
                    if (reply.answer != null) return error.InvalidArchive;
                    try requireArchiveRecord(
                        validation.records,
                        .workspace_port_reply,
                        reply.attempt,
                    );
                    var answer = try Records.record(
                        validation.service,
                        workspace.PortReply,
                        validation.a,
                        "workspace_port_reply",
                        reply.attempt,
                        validation.task_id,
                    );
                    defer answer.deinit();
                    if (!std.meta.eql(answer.value.task, validation.task_id) or
                        !std.meta.eql(answer.value.id, reply.attempt) or
                        !std.meta.eql(answer.value.port, validation.reference) or !std.meta.eql(
                        answer.value.reply.digest,
                        reply.reply,
                    )) return error.InvalidArchive;
                    var result = try data.invocation.decode(
                        data.invocation.Result,
                        validation.a,
                        try store(validation.service).object(
                            validation.a,
                            answer.value.reply,
                            null,
                        ),
                    );
                    defer result.deinit();
                    if (!std.meta.eql(result.value.request_identity, validation.pending.request))
                        return error.InvalidArchive;
                    try validation.validateCommand(port, work, answer.value, result.value);
                }
                fn validateCommand(
                    validation: *@This(),
                    port: workspace.Port,
                    work: workspace.Work,
                    answer: workspace.PortReply,
                    result: data.invocation.Result,
                ) !void {
                    const protocol: @import("../workspace_driver.zig").Protocol = .{
                        .class = port.interface.class,
                        .command_schema = validation.request.binding.resume_schema,
                        .payload_schema = validation.request.binding.payload_schema,
                        .payload = validation.request.binding.payload,
                    };
                    const command = try protocol.decode(validation.a, result.value);
                    if (answer.command == .finish) {
                        if (command != .finish or answer.input != null)
                            return error.InvalidArchive;
                    } else {
                        if (command != .resume_value) return error.InvalidArchive;
                        const input = answer.input orelse return error.InvalidArchive;
                        const origin = try workspaceValueReference(
                            validation.service,
                            validation.a,
                            validation.task_id,
                            try wp.reference(validation.a, .value, input.digest),
                        );
                        if (!std.meta.eql(origin.artifact, input) or !std.meta.eql(
                            origin.schema,
                            port.interface.argument,
                        )) return error.InvalidArchive;
                        const input_bytes = command.resume_value;
                        if (!std.meta.eql(origin.value, state.Reference{
                            .digest = storage.digest(input_bytes),
                            .bytes = input_bytes.len,
                        })) return error.InvalidArchive;
                        var found = false;
                        for (work.inputs.items) |source| found = found or
                            std.meta.eql(source, input);
                        if (!found) return error.InvalidArchive;
                    }
                }
            };
        }
        pub fn validateOccurrenceProvenance(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            var proof: OccurrenceProof = .{
                .service = self,
                .a = a,
                .value = value,
                .records = records,
                .checked = checked,
                .residual_occurrences = .init(a),
                .images = .init(a),
            };
            defer proof.residual_occurrences.deinit();
            defer proof.images.deinit();
            try proof.residuals();
            for (records) |row| try proof.occurrenceRow(row);
            try proof.questions();
        }
        const OccurrenceProof = occurrenceProofType();
        fn occurrenceProofType() type {
            return struct {
                service: *Self,
                a: std.mem.Allocator,
                value: state.Task,
                records: []const state.ArchiveRecord,
                checked: *Snapshots.SnapshotValidation,
                residual_occurrences: std.AutoHashMap(state.Digest, state.Digest),
                images: std.AutoHashMap(state.Reference, state.Digest),
                fn residuals(proof: *@This()) !void {
                    for (proof.records) |row| if (row.kind == .controller_residual) {
                        var residual = try Records.record(
                            proof.service,
                            state.ControllerResidual,
                            proof.a,
                            "controller_residual",
                            row.id,
                            proof.value.id,
                        );
                        defer residual.deinit();
                        if (residual.value.current_occurrence) |id| {
                            if (std.meta.eql(proof.value.current_occurrence, id) or
                                proof.residual_occurrences.contains(id))
                                return error.InvalidArchive;
                            try proof.residual_occurrences.put(id, row.id);
                        }
                    };
                }
                fn occurrenceRow(proof: *@This(), row: state.ArchiveRecord) !void {
                    if (row.kind != .occurrence) return;
                    var arena = std.heap.ArenaAllocator.init(proof.service.allocator);
                    defer arena.deinit();
                    const temporary = arena.allocator();
                    var decoded = try Records.record(
                        proof.service,
                        occurrence.Occurrence,
                        temporary,
                        "occurrence",
                        row.id,
                        proof.value.id,
                    );
                    defer decoded.deinit();
                    const saved = decoded.value;
                    try requireArchiveRecord(proof.records, .execution_route, saved.id);
                    var route = try Records.record(
                        proof.service,
                        workspace.ExecutionRoute,
                        temporary,
                        "execution_route",
                        saved.id,
                        proof.value.id,
                    );
                    defer route.deinit();
                    const expected_image = try proof.resolveRoute(temporary, saved, route.value);
                    const encoded =
                        try store(proof.service).object(temporary, saved.request_object, null);
                    var request =
                        try data.invocation.decode(data.invocation.Request, temporary, encoded);
                    defer request.deinit();
                    try proof.requestIdentity(
                        temporary,
                        saved,
                        route.value,
                        expected_image,
                        request.value,
                    );
                    var evidence: OccurrenceEvidence = .{
                        .proof = proof,
                        .temporary = temporary,
                        .saved = saved,
                        .route = route.value,
                        .request = request.value,
                    };
                    try evidence.validate();
                }
                fn resolveRoute(
                    proof: *@This(),
                    temporary: std.mem.Allocator,
                    saved: occurrence.Occurrence,
                    route: workspace.ExecutionRoute,
                ) !state.Reference {
                    if (!std.meta.eql(route.task, proof.value.id) or
                        !std.meta.eql(route.id, saved.id) or
                        !std.meta.eql(route.work, saved.work) or
                        !std.meta.eql(route.residual, saved.residual) or (saved.work != null and
                        saved.residual != null)) return error.InvalidArchive;
                    var current_id = proof.value.current_occurrence;
                    var expected_image = if (saved.work == null) try rootRouteImage(
                        proof.service,
                        temporary,
                        proof.value,
                        route,
                    ) else proof.value.image;
                    current_id = try proof.currentId(temporary, saved, route, current_id);
                    if (saved.work) |work_id| {
                        try requireArchiveRecord(proof.records, .workspace_work, work_id);
                        var work =
                            try workspaceWork(proof.service, temporary, proof.value.id, work_id);
                        defer work.deinit();
                        var program = try workspaceProgram(
                            proof.service,
                            temporary,
                            proof.value.id,
                            work.value.program,
                        );
                        defer program.deinit();
                        expected_image = program.value.description.image;
                        current_id = work.value.current_occurrence;
                    }
                    if (!std.meta.eql(expected_image, route.image)) return error.InvalidArchive;
                    const is_current = if (current_id) |id| same(&id, &saved.id) else false;
                    if (is_current == (saved.state == .admitted)) return error.InvalidArchive;
                    return expected_image;
                }
                fn currentId(
                    proof: *@This(),
                    temporary: std.mem.Allocator,
                    saved: occurrence.Occurrence,
                    route: workspace.ExecutionRoute,
                    initial: ?state.Digest,
                ) !?state.Digest {
                    var current_id = initial;
                    if (saved.residual) |id| {
                        try requireArchiveRecord(proof.records, .controller_residual, id);
                        var residual = try Records.record(
                            proof.service,
                            state.ControllerResidual,
                            temporary,
                            "controller_residual",
                            id,
                            proof.value.id,
                        );
                        defer residual.deinit();
                        if (!std.meta.eql(route.controller, residual.value.controller))
                            return error.InvalidArchive;
                        current_id = residual.value.current_occurrence;
                    } else if (proof.residual_occurrences.get(saved.id)) |id| {
                        var residual = try Records.record(
                            proof.service,
                            state.ControllerResidual,
                            temporary,
                            "controller_residual",
                            id,
                            proof.value.id,
                        );
                        defer residual.deinit();
                        if (saved.work != null or residual.value.cancellation_applied or
                            !std.meta.eql(route.controller, residual.value.controller))
                            return error.InvalidArchive;
                        current_id = saved.id;
                    }
                    return current_id;
                }
                fn requestIdentity(
                    proof: *@This(),
                    temporary: std.mem.Allocator,
                    saved: occurrence.Occurrence,
                    route: workspace.ExecutionRoute,
                    expected_image: state.Reference,
                    request: data.invocation.Request,
                ) !void {
                    const identity = proof.images.get(expected_image) orelse identity: {
                        var image = try data.program_image.decode(
                            temporary,
                            try store(proof.service).object(temporary, expected_image, null),
                        );
                        defer image.deinit();
                        try proof.images.put(expected_image, image.identity);
                        break :identity image.identity;
                    };
                    if (!same(&request.request_identity, &saved.request) or
                        !same(&request.binding.program_identity, &identity) or
                        !same(&route.program_identity, &identity)) return error.InvalidArchive;
                }
                fn questions(proof: *@This()) !void {
                    // A retained question (including one named by an answer receipt)
                    // must also have its occurrence, rather than becoming replay debris.
                    for (proof.records) |row| {
                        if (row.kind != .question) continue;
                        var question = try Records.record(
                            proof.service,
                            state.Question,
                            proof.a,
                            "question",
                            row.id,
                            proof.value.id,
                        );
                        defer question.deinit();
                        try requireArchiveRecord(
                            proof.records,
                            .occurrence,
                            question.value.occurrence,
                        );
                        var saved = try Records.record(
                            proof.service,
                            occurrence.Occurrence,
                            proof.a,
                            "occurrence",
                            question.value.occurrence,
                            proof.value.id,
                        );
                        defer saved.deinit();
                        const question_id: ?state.Digest = switch (saved.value.state) {
                            .awaiting => |waiting| waiting.question,
                            .settled_reply => |reply| if (reply.answer) |answer|
                                answer.question
                            else
                                null,
                            .admitted => |admitted| switch (admitted) {
                                .reply => |reply| blk: {
                                    break :blk if (reply.answer) |answer| answer.question else null;
                                },
                                .cancelled => |waiting| if (waiting) |pending|
                                    pending.question
                                else
                                    null,
                            },
                            else => null,
                        };
                        if (question_id == null or !same(&question_id.?, &row.id))
                            return error.InvalidArchive;
                    }
                }
            };
        }
        const OccurrenceEvidence = occurrenceEvidenceType();
        fn occurrenceEvidenceType() type {
            return struct {
                proof: *OccurrenceProof,
                temporary: std.mem.Allocator,
                saved: occurrence.Occurrence,
                route: workspace.ExecutionRoute,
                request: data.invocation.Request,
                fn validate(evidence: *@This()) !void {
                    if (evidence.route.port) |port| {
                        if (evidence.saved.work == null or evidence.route.delegation != null)
                            return error.InvalidArchive;
                        try validateWorkspacePortOccurrence(
                            evidence.proof.service,
                            evidence.temporary,
                            evidence.proof.value.id,
                            evidence.saved,
                            port,
                            evidence.request,
                            evidence.proof.records,
                        );
                        return;
                    }
                    try evidence.delegation();
                    // Cancellation can retire READY before a handler is available.
                    // Neither that state nor READY claims any acquisition.
                    if (evidence.saved.state == .ready or
                        (evidence.saved.state == .admitted and
                            evidence.saved.state.admitted == .cancelled and
                            evidence.saved.state.admitted.cancelled == null))
                        return;
                    if (try evidence.trial()) return;
                    if (controllerInternal(evidence.request.binding.semantic_identity))
                        return evidence.internal();
                    const entry = try evidence.proof.service.handlers.resolve(
                        evidence.request,
                        evidence.route.program_identity,
                    );
                    if (evidence.saved.residual != null and (entry.declaration.inference or
                        (entry.declaration.kind != .leaf and entry.declaration.kind != .workspace)))
                        return error.InvalidArchive;
                    const acquired: ?occurrence.Acquired = switch (evidence.saved.state) {
                        .settled_reply => |reply| reply,
                        .admitted => |admitted| if (admitted == .reply) admitted.reply else null,
                        .awaiting, .not_sent, .unknown, .captured => null,
                        else => return error.UnsettledOccurrence,
                    };
                    const reply_value = try evidence.replyValue(entry, acquired);
                    switch (entry.declaration.kind) {
                        .leaf => try evidence.leaf(entry, acquired),
                        .workspace => try evidence.workspaceEvidence(entry, acquired, reply_value),
                        .inbox => try evidence.inbox(acquired, reply_value),
                        .question => try evidence.questionEvidence(entry, acquired, reply_value),
                    }
                }
                fn delegation(evidence: *@This()) !void {
                    if (evidence.saved.work) |id| {
                        var work = try workspaceWork(
                            evidence.proof.service,
                            evidence.temporary,
                            evidence.proof.value.id,
                            id,
                        );
                        defer work.deinit();
                        if (work.value.trial != null) {
                            if (evidence.route.delegation != null) return error.InvalidArchive;
                        } else {
                            if (work.value.delegation == null or !std.meta.eql(
                                work.value.delegation,
                                evidence.route.delegation,
                            ) or !std.meta.eql(work.value.instrument_occurrence, evidence.saved.id))
                                return error.InvalidArchive;
                            const input = try contracts.decodeOwned(
                                instrument.Input,
                                evidence.temporary,
                                evidence.request.binding.payload,
                            );
                            if (!std.meta.eql(input.value.delegation, work.value.delegation.?))
                                return error.InvalidArchive;
                        }
                    }
                }
                fn trial(evidence: *@This()) !bool {
                    if (evidence.saved.work) |work_id| {
                        var child = try workspaceWork(
                            evidence.proof.service,
                            evidence.temporary,
                            evidence.proof.value.id,
                            work_id,
                        );
                        defer child.deinit();
                        if (child.value.trial != null) {
                            if (controllerTrialReply(
                                evidence.proof.service,
                                evidence.temporary,
                                child.value,
                                evidence.request,
                            )) |expected| {
                                const acquired = switch (evidence.saved.state) {
                                    .settled_reply => |reply| reply,
                                    .admitted => |admitted| if (admitted ==
                                        .reply) admitted.reply else return error.InvalidArchive,
                                    else => return error.InvalidArchive,
                                };
                                if (acquired.answer != null or !std.meta.eql(
                                    acquired.attempt,
                                    evidence.saved.id,
                                )) return error.InvalidArchive;
                                var reply = try data.invocation.decode(
                                    data.invocation.Result,
                                    evidence.temporary,
                                    try store(evidence.proof.service).acquiredObject(
                                        evidence.temporary,
                                        acquired.reply,
                                        null,
                                    ),
                                );
                                defer reply.deinit();
                                if (!std.meta.eql(
                                    reply.value.request_identity,
                                    evidence.saved.request,
                                ) or !same(reply.value.value, expected))
                                    return error.InvalidArchive;
                                return true;
                            } else |err| {
                                if (err != error.ObservationUnavailable or
                                    !try controllerTrialAllowsLive(
                                        evidence.proof.service,
                                        evidence.temporary,
                                        child.value,
                                        evidence.request,
                                    )) return error.InvalidArchive;
                            }
                        }
                    }
                    return false;
                }
                fn internal(evidence: *@This()) !void {
                    if (evidence.saved.residual != null) return error.InvalidArchive;
                    const acquired = switch (evidence.saved.state) {
                        .settled_reply => |reply| reply,
                        .admitted => |admitted| if (admitted ==
                            .reply) admitted.reply else return error.InvalidArchive,
                        else => return error.InvalidArchive,
                    };
                    if (acquired.answer != null) return error.InvalidArchive;
                    const bytes = try store(evidence.proof.service).acquiredObject(
                        evidence.temporary,
                        acquired.reply,
                        null,
                    );
                    var reply = try data.invocation.decode(
                        data.invocation.Result,
                        evidence.temporary,
                        bytes,
                    );
                    defer reply.deinit();
                    if (!std.meta.eql(reply.value.request_identity, evidence.saved.request) or
                        !same(
                            reply.value.value,
                            try controllerStoredReply(
                                evidence.proof.service,
                                evidence.temporary,
                                evidence.proof.value,
                                evidence.saved,
                                evidence.request,
                            ),
                        )) return error.InvalidArchive;
                    return;
                }
                fn replyValue(
                    evidence: *@This(),
                    entry: registry.Entry,
                    acquired: ?occurrence.Acquired,
                ) !?[]const u8 {
                    var reply_value: ?[]const u8 = null;
                    if (acquired) |reply| {
                        const bytes = try store(
                            evidence.proof.service,
                        ).acquiredObject(evidence.temporary, reply.reply, null);
                        const result = try data.invocation.decode(
                            data.invocation.Result,
                            evidence.temporary,
                            bytes,
                        );
                        // Keep the decoded backing until this iteration's arena ends.
                        if (!same(&result.value.request_identity, &evidence.saved.request))
                            return error.InvalidArchive;
                        var schema =
                            try data.schema.decode(evidence.temporary, entry.resume_schema);
                        defer schema.deinit();
                        try data.schema.validateValue(
                            evidence.temporary,
                            schema.descriptor,
                            result.value.value,
                        );
                        reply_value = result.value.value;
                    }
                    return reply_value;
                }
                fn leaf(
                    evidence: *@This(),
                    entry: registry.Entry,
                    acquired: ?occurrence.Acquired,
                ) !void {
                    const attempt_id =
                        if (acquired) |reply|
                            reply.attempt
                        else switch (evidence.saved.state) {
                            .not_sent, .unknown, .captured => |attempt| attempt.id,
                            else => return error.InvalidArchive,
                        };
                    if (acquired) |reply| if (reply.answer != null) return error.InvalidArchive;
                    try requireArchiveRecord(evidence.proof.records, .attempt, attempt_id);
                    var attempt = try Records.record(
                        evidence.proof.service,
                        state.Attempt,
                        evidence.temporary,
                        "attempt",
                        attempt_id,
                        evidence.proof.value.id,
                    );
                    defer attempt.deinit();
                    if (!same(&attempt.value.occurrence, &evidence.saved.id) or !std.meta.eql(
                        attempt.value.request,
                        evidence.saved.request_object,
                    )) return error.InvalidArchive;
                    if (evidence.saved.state == .captured and entry.declaration.capture == null)
                        return error.InvalidArchive;
                    if ((acquired != null and entry.declaration.capture != null) or
                        evidence.saved.state == .captured)
                    {
                        try requireArchiveRecord(evidence.proof.records, .capture, attempt_id);
                        var raw_capture = try Records.record(
                            evidence.proof.service,
                            state.Capture,
                            evidence.temporary,
                            "capture",
                            attempt_id,
                            evidence.proof.value.id,
                        );
                        defer raw_capture.deinit();
                        if (!same(&raw_capture.value.occurrence, &evidence.saved.id))
                            return error.InvalidArchive;
                    }
                }
                fn workspaceEvidence(
                    evidence: *@This(),
                    entry: registry.Entry,
                    acquired: ?occurrence.Acquired,
                    reply_value: ?[]const u8,
                ) !void {
                    if (acquired == null) {
                        const attempt_id = switch (evidence.saved.state) {
                            .captured, .unknown, .not_sent => |attempt| attempt.id,
                            else => return error.InvalidArchive,
                        };
                        try requireArchiveRecord(evidence.proof.records, .attempt, attempt_id);
                        var attempt = try Records.record(
                            evidence.proof.service,
                            state.Attempt,
                            evidence.temporary,
                            "attempt",
                            attempt_id,
                            evidence.proof.value.id,
                        );
                        defer attempt.deinit();
                        if (attempt.value.operation != .workspace_build or !std.meta.eql(
                            attempt.value.request,
                            evidence.saved.request_object,
                        )) return error.InvalidArchive;
                        if (evidence.saved.state == .captured)
                            try requireArchiveRecord(evidence.proof.records, .capture, attempt_id);
                        return;
                    }
                    try evidence.workspaceReply(entry, acquired.?, reply_value.?);
                }
                fn workspaceReply(
                    evidence: *@This(),
                    entry: registry.Entry,
                    reply: occurrence.Acquired,
                    reply_value: []const u8,
                ) !void {
                    if (reply.answer != null) return error.InvalidArchive;
                    if (try store(evidence.proof.service).recordBytes(
                        evidence.temporary,
                        "workspace_reply",
                        evidence.saved.id,
                        evidence.proof.value.id,
                    )) |bytes| {
                        try requireArchiveRecord(
                            evidence.proof.records,
                            .workspace_reply,
                            evidence.saved.id,
                        );
                        var observation = try contracts.decodeOwned(
                            workspace.ReplyObservation,
                            evidence.temporary,
                            bytes,
                        );
                        defer observation.deinit();
                        try validateWorkspaceReply(
                            evidence.proof.service,
                            evidence.temporary,
                            evidence.proof.value,
                            evidence.saved,
                            entry,
                            evidence.request,
                            observation.value,
                            reply_value,
                            evidence.proof.records,
                            evidence.proof.checked,
                        );
                    } else {
                        try requireArchiveRecord(evidence.proof.records, .attempt, reply.attempt);
                        try requireArchiveRecord(evidence.proof.records, .capture, reply.attempt);
                        var attempt = try Records.record(
                            evidence.proof.service,
                            state.Attempt,
                            evidence.temporary,
                            "attempt",
                            reply.attempt,
                            evidence.proof.value.id,
                        );
                        defer attempt.deinit();
                        if (attempt.value.operation != .workspace_build or !std.meta.eql(
                            attempt.value.occurrence,
                            evidence.saved.id,
                        )) return error.InvalidArchive;
                    }
                }
                fn inbox(
                    evidence: *@This(),
                    acquired: ?occurrence.Acquired,
                    reply_value: ?[]const u8,
                ) !void {
                    const reply = acquired orelse return error.InvalidArchive;
                    if (reply.answer != null) return error.InvalidArchive;
                    _ = try validateInboxReply(
                        evidence.proof.service,
                        evidence.temporary,
                        evidence.proof.value.id,
                        evidence.saved,
                        reply_value.?,
                    );
                }
                fn questionEvidence(
                    evidence: *@This(),
                    entry: registry.Entry,
                    acquired: ?occurrence.Acquired,
                    reply_value: ?[]const u8,
                ) !void {
                    const waiting: ?occurrence.Waiting = switch (evidence.saved.state) {
                        .awaiting => |pending| pending,
                        .admitted => |admitted| if (admitted ==
                            .cancelled) admitted.cancelled else null,
                        else => null,
                    };
                    const answer: ?occurrence.Answer = if (acquired) |reply| reply.answer orelse
                        return error.InvalidArchive else null;
                    const question_id =
                        if (waiting) |pending|
                            pending.question
                        else if (answer) |bound|
                            bound.question
                        else
                            return error.InvalidArchive;
                    try requireArchiveRecord(evidence.proof.records, .question, question_id);
                    var question = try Records.record(
                        evidence.proof.service,
                        state.Question,
                        evidence.temporary,
                        "question",
                        question_id,
                        evidence.proof.value.id,
                    );
                    defer question.deinit();
                    const q = question.value;
                    if (q.retired != (evidence.saved.state == .admitted) or q.revision == 0 or
                        !same(&q.occurrence, &evidence.saved.id) or
                        !same(&q.request_digest, &evidence.saved.request) or
                        !std.meta.eql(q.request, evidence.saved.request_object) or
                        !same(&q.pending_digest, &evidence.request.binding.pending_state_digest) or
                        !same(&q.answer_schema_digest, &storage.digest(entry.resume_schema)) or
                        !same(q.answer_schema_id.bytes, entry.declaration.answer_schema_id.?))
                        return error.InvalidArchive;
                    if (waiting) |pending| {
                        if (q.answer != null or q.receipt != null or !same(
                            &pending.pending_digest,
                            &q.pending_digest,
                        )) return error.InvalidArchive;
                    } else {
                        try evidence.questionAnswer(q, question_id, answer.?, reply_value.?);
                    }
                }
                fn questionAnswer(
                    evidence: *@This(),
                    q: state.Question,
                    question_id: state.Digest,
                    bound: occurrence.Answer,
                    reply_value: []const u8,
                ) !void {
                    const reference = q.answer orelse return error.InvalidArchive;
                    const answer_receipt = q.receipt orelse return error.InvalidArchive;

                    if (!same(&reference.digest, &storage.digest(reply_value)) or
                        reference.bytes != reply_value.len or
                        !same(&bound.digest, &reference.digest) or
                        !same(&bound.pending_digest, &q.pending_digest) or
                        !same(&answer_receipt.task, &evidence.proof.value.id) or
                        answer_receipt.method != .respond or
                        answer_receipt.disposition != .answer_acquired or
                        answer_receipt.question == null or !same(
                        &answer_receipt.question.?,
                        &question_id,
                    )) return error.InvalidArchive;
                    const bytes = try store(evidence.proof.service).object(
                        evidence.temporary,
                        reference,
                        null,
                    );
                    const expected = try answerDigest(
                        evidence.temporary,
                        evidence.proof.value.id,
                        question_id,
                        q.revision,
                        q.request_digest,
                        q.answer_schema_id.bytes,
                        bytes,
                    );
                    if (!same(&expected, &answer_receipt.request_digest))
                        return error.InvalidArchive;
                    const key = try operationKey(
                        evidence.proof.service,
                        evidence.temporary,
                        answer_receipt.client_operation_id.bytes,
                    );
                    const receipt_bytes = (try store(
                        evidence.proof.service,
                    ).savedReceipt(evidence.temporary, &key)) orelse return error.InvalidArchive;
                    if (!same(
                        receipt_bytes,
                        try contracts.encodeOwned(
                            state.Receipt,
                            evidence.temporary,
                            answer_receipt,
                        ),
                    )) return error.InvalidArchive;
                }
            };
        }
    };
}
