const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const kosmos = @import("kosmos");
const workspace = @import("../workspace_state.zig");
const instrument = @import("../workspace_instrument.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const Work = task_types.Work;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const authorizeWorkspace = Access.authorizeWorkspace;
        const capsuleDependencies = Realization.capsuleDependencies;
        const compatibleApplication = Admission.compatibleApplication;
        const compilerReference = Compiler.compilerReference;
        const controllerRuntimeAt = Realization.controllerRuntimeAt;
        const inspectionRuntime = Inspection.inspectionRuntime;
        const occurrenceImage = Root.occurrenceImage;
        const prepareCompilerFacts = Compiler.prepareCompilerFacts;
        const record = Records.record;
        const requireArchiveRecord = Occurrences.requireArchiveRecord;
        const samePublication = Access.samePublication;
        const store = Lifecycle.store;
        const validateCancellation = Checkpoint.validateCancellation;
        const validateCapturedProjections = ArchiveCaptures.validateCapturedProjections;
        const validateControllerViewIn = Context.validateControllerViewIn;
        const validateDelegatedValue = Inspection.validateDelegatedValue;
        const validateGuardAgreement = Guards.validateGuardAgreement;
        const validateGuardSnapshot = Guards.validateGuardSnapshot;
        const validateObserver = Observers.validateObserver;
        const validateOccurrenceProvenance = Occurrences.validateOccurrenceProvenance;
        const validateOuterControl = Realization.validateOuterControl;
        const validatePublishedCapsule = Realization.validatePublishedCapsule;
        const validatePublishedCapsuleTrace = Realization.validatePublishedCapsuleTrace;
        const validateWorkspaceControllerBindings =
            WorkspaceRecords.validateWorkspaceControllerBindings;
        const validateWorkspaceGenerations = WorkspaceRecords.validateWorkspaceGenerations;
        const validateWorkspacePublications = Replay.validateWorkspacePublications;
        const validateWorkspaceReadIn = Replay.validateWorkspaceReadIn;
        const validateWorkspaceReceipts = WorkspaceRecords.validateWorkspaceReceipts;
        const validateWorkspaceRecordBody = WorkspaceRecords.validateWorkspaceRecordBody;
        const workPublication = Access.workPublication;
        const workspaceContentCustody = Programs.workspaceContentCustody;
        const workspaceInteractionReply = WorkspaceAdmission.workspaceInteractionReply;
        const workspaceResultDerivation = Execution.workspaceResultDerivation;
        const workspaceRuntime = Programs.workspaceRuntime;
        const workspaceSnapshotRange = Inspection.workspaceSnapshotRange;
        const workspaceValueReference = Contexts.workspaceValueReference;
        const workspaceValueReferenceIn = Contexts.workspaceValueReferenceIn;
        const Admission = @import("admission.zig").Operations(Types, Self);
        const ArchiveCaptures = @import("archive_captures.zig").Operations(Types, Self);
        const Occurrences = @import("archive_occurrences.zig").Operations(Types, Self);
        const Checkpoint = @import("checkpoint.zig").Operations(Types, Self);
        const Compiler = @import("compiler_preparation.zig").Operations(Types, Self);
        const Context = @import("controller_context.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Root = @import("root_execution.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const WorkspaceAdmission = @import("workspace_admission.zig").Operations(Types, Self);
        const Contexts = @import("workspace_contexts.zig").Operations(Types, Self);
        const Execution = @import("workspace_execution.zig").Operations(Types, Self);
        const Guards = @import("workspace_guards.zig").Operations(Types, Self);
        const Inspection = @import("workspace_inspection.zig").Operations(Types, Self);
        const Observers = @import("workspace_observers.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Realization = @import("workspace_realization.zig").Operations(Types, Self);
        const WorkspaceRecords = @import("workspace_records.zig").Operations(Types, Self);
        const Replay = @import("workspace_replay.zig").Operations(Types, Self);
        pub fn validateWorkspace(
            self: *Self,
            allocator: std.mem.Allocator,
            task_id: state.TaskId,
        ) !void {
            var phase: []const u8 = "task and archive index";
            errdefer std.debug.print("workspace validation: {s}\n", .{phase});
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            const index = try store(self).archiveIndex(a, task_id, .{
                .digest = storage.digest(self.assets.manifest),
                .bytes = self.assets.manifest.len,
            });
            phase = "records";
            try validateWorkspaceRecords(self, a, task_id, index.records.items);
        }
        pub fn validateDelegation(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            row: state.ArchiveRecord,
            records: []const state.ArchiveRecord,
        ) !void {
            var saved = try record(
                self,
                workspace.Delegation,
                a,
                "workspace_delegation",
                row.id,
                parent.id,
            );
            defer saved.deinit();
            const value = saved.value;
            if (!std.meta.eql(value.id, row.id) or !std.meta.eql(value.task, parent.id))
                return error.InvalidArchive;
            try requireArchiveRecord(records, .occurrence, value.parent_occurrence);
            try requireArchiveRecord(records, .workspace_work, value.instrument);
            try requireArchiveRecord(records, .workspace_work, value.work);
            var original = try record(
                self,
                occurrence.Occurrence,
                a,
                "occurrence",
                value.parent_occurrence,
                parent.id,
            );
            defer original.deinit();
            if (original.value.work != null or !std.meta.eql(
                original.value.request_object,
                value.parent_request,
            )) return error.InvalidArchive;
            var request = try data.invocation.decode(
                data.invocation.Request,
                a,
                try store(self).object(a, value.parent_request, null),
            );
            defer request.deinit();
            const entry = try self.handlers.resolve(
                request.value,
                try occurrenceImage(self, a, parent, original.value),
            );
            if (entry.declaration.kind != .workspace) return error.InvalidArchive;
            var authorized = try contracts.decodeOwned(
                workspace.Authorized,
                a,
                try authorizeWorkspace(self, a, parent, entry, request.value.binding.payload),
            );
            defer authorized.deinit();
            if (authorized.value.command != .work or authorized.value.command.work != .delegate)
                return error.InvalidArchive;
            try validateDelegationSelection(a, value, authorized.value);
            const selection = authorized.value.command.work.delegate;
            try validateDelegatedPort(self, a, parent, value, selection);
            try validateDelegatedChild(self, a, parent, row, value, selection);
        }
        pub fn prepareWorkspaceValidation(
            self: *Self,
            task_id: state.TaskId,
        ) !Compiler.CompilerFacts {
            if (store(self).transaction) return error.InvalidState;
            var facts: Compiler.CompilerFacts = .{ .allocator = self.allocator };
            errdefer facts.deinit();
            const prior = self.compiler_facts;
            self.compiler_facts = &facts;
            defer self.compiler_facts = prior;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const manifest = try store(self).archiveIndex(
                arena.allocator(),
                task_id,
                compilerReference(self.assets.manifest),
            );
            try prepareCompilerFacts(self, manifest, store(self));
            return facts;
        }
        pub fn validateWorkspaceRecordsPrepared(
            self: *Self,
            allocator: std.mem.Allocator,
            task_id: state.TaskId,
            records: []const state.ArchiveRecord,
            facts: *Compiler.CompilerFacts,
        ) !void {
            const prior = self.compiler_facts;
            self.compiler_facts = facts;
            defer self.compiler_facts = prior;
            try validateWorkspaceRecords(self, allocator, task_id, records);
        }
        pub fn validateWorkspaceRecords(
            self: *Self,
            allocator: std.mem.Allocator,
            task_id: state.TaskId,
            records: []const state.ArchiveRecord,
        ) !void {
            var phase: []const u8 = "task";
            errdefer std.debug.print("workspace records: {s}\n", .{phase});
            var compiler_facts: Compiler.CompilerFacts = .{ .allocator = self.allocator };
            defer compiler_facts.deinit();
            const prior_compiler_facts = self.compiler_facts;
            if (self.compiler_facts == null) self.compiler_facts = &compiler_facts;
            defer self.compiler_facts = prior_compiler_facts;
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            phase = "archive records";
            try validateWorkspaceArchive(self, a, parent.value, records, .records);
        }
        pub fn validateWorkspaceArchive(
            self: *Self,
            allocator: std.mem.Allocator,
            parent: state.Task,
            records: []const state.ArchiveRecord,
            mode: enum {
                records,
                inspect,
                retain,
            },
        ) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var checked: SnapshotValidation = .{
                .allocator = a,
                .observer_successors = .init(self.allocator, parent.id),
                .semantic_sources = true,
            };
            defer checked.deinit();
            try validateOccurrenceProvenance(self, a, parent, records, &checked);
            if (mode != .records)
                try validateCapturedProjections(
                    self,
                    parent,
                    records,
                    if (mode == .inspect) .inspect else .retain,
                    &checked,
                );
            try validateWorkspaceRecordBodies(self, a, parent.id, records, &checked);
        }
        fn validateWorkspaceRecordBodies(
            self: *Self,
            allocator: std.mem.Allocator,
            task_id: state.TaskId,
            records: []const state.ArchiveRecord,
            checked: *SnapshotValidation,
        ) !void {
            var phase: []const u8 = "task and controller";
            errdefer std.debug.print("workspace record bodies: {s}\n", .{phase});
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try compatibleApplication(self, parent.value);
            const runtime_cut =
                try controllerRuntimeAt(self, a, parent.value, parent.value.event_high);
            if (!std.meta.eql(runtime_cut.runtime, parent.value.controller_runtime) or
                runtime_cut.realization_revision != parent.value.realization_revision)
                return error.InvalidArchive;
            phase = "publications";
            try validateWorkspacePublications(self, a, parent.value, records, checked);
            phase = "receipts";
            try validateWorkspaceReceipts(self, a, parent.value, records, checked);
            phase = "controller bindings";
            try validateWorkspaceControllerBindings(self, a, parent.value, records);
            const Generation = struct { work: state.Digest, generation: u64 };
            var generations: std.AutoHashMap(Generation, void) = .init(a);
            for (records) |row| {
                var record_arena = std.heap.ArenaAllocator.init(self.allocator);
                defer record_arena.deinit();
                const frame = record_arena.allocator();
                phase = @tagName(row.kind);
                try validateWorkspaceRecordBody(
                    self,
                    frame,
                    parent.value,
                    row,
                    records,
                    checked,
                    &generations,
                );
            }
            try validateWorkspaceGenerations(self, parent.value, records, checked, &generations);
        }
        fn validateWorkspaceInputs(self: *Self, a: std.mem.Allocator, value: workspace.Work) !void {
            var count: usize = 0;
            if (value.observer) |observer| {
                if (value.inputs.items.len < 2 or
                    !std.meta.eql(value.inputs.items[0], observer.source) or
                    !std.meta.eql(value.inputs.items[1], observer.accumulator))
                    return error.InvalidArchive;
                count = 2;
            }
            if (value.trial) |id| {
                var trial =
                    try record(self, workspace.Trial, a, "workspace_trial", id, value.task);
                defer trial.deinit();
                for (trial.value.responses.items) |response| {
                    if (value.inputs.items.len -| count < 2 or
                        !std.meta.eql(value.inputs.items[count], response.payload) or !std.meta.eql(
                        value.inputs.items[count + 1],
                        response.response,
                    )) return error.InvalidArchive;
                    count += 2;
                }
            }
            var query = try store(self).database.prepare(
                "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                    "ERE e.task=? AND e.seq<=? ORDER BY e.seq",
                &.{ .{ .blob = &value.task }, .{
                    .integer = std.math.cast(i64, value.event_watermark) orelse
                        return error.InvalidArchive,
                } },
            );
            defer query.deinit();
            while (try query.step() == .row) {
                var event_value = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                defer event_value.deinit();
                const ref = event_value.value.workspace_command orelse continue;
                var command = try contracts.decodeOwned(
                    workspace.PublicationCommand,
                    a,
                    try store(self).object(a, ref, null),
                );
                defer command.deinit();
                if (command.value != .interact or !std.meta.eql(
                    try wp.identity(command.value.interact.expected.work, .work),
                    value.id,
                )) continue;
                const reply =
                    try workspaceInteractionReply(self, a, value.task, command.value.interact);
                if (reply.input) |input| {
                    if (count >= value.inputs.items.len or !std.meta.eql(
                        value.inputs.items[count],
                        input,
                    )) return error.InvalidArchive;
                    count += 1;
                }
            }
            if (value.answer_value) |answer| {
                if (count >= value.inputs.items.len or
                    !std.meta.eql(value.inputs.items[count], answer)) return error.InvalidArchive;
                count += 1;
            }
            if (count != value.inputs.items.len) return error.InvalidArchive;
        }
        pub fn validateWorkspacePublication(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            snapshot: workspace.WorkObservation,
        ) !void {
            const value = snapshot.work;
            if (!std.meta.eql(value.task, task_id)) return error.InvalidArchive;
            const publication_binding = try workPublication(a, snapshot);
            var event_query = try store(self).database.prepare(
                "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                    "ERE e.task=? AND e.seq=?",
                &.{ .{ .blob = &task_id }, .{
                    .integer = std.math.cast(i64, value.event_watermark) orelse
                        return error.InvalidArchive,
                } },
            );
            defer event_query.deinit();
            if (try event_query.step() != .row) return error.InvalidArchive;
            var published = try contracts.decodeOwned(state.Event, a, try event_query.bytes(0));
            defer published.deinit();
            var matches: usize = 0;
            for (published.value.workspace_publications.items) |item| if (try samePublication(
                a,
                item,
                publication_binding,
            )) {
                matches += 1;
            };
            if (matches != 1) return error.InvalidArchive;
        }
        pub const SnapshotValidation = snapshotValidationType();
        fn snapshotValidationType() type {
            return struct {
                pub const Key = struct {
                    kind: enum { snapshot, semantic_source },
                    task: state.TaskId,
                    identity: state.Digest,
                };
                allocator: std.mem.Allocator,
                facts: std.AutoHashMapUnmanaged(Key, enum { visiting, checked }) = .empty,
                observer_successors: Observers.ObserverSuccessors,
                semantic_sources: bool = false,
                controller_values: std.AutoHashMapUnmanaged(state.Digest, state.ControllerReadCut) =
                    .empty,

                pub fn deinit(self: *SnapshotValidation) void {
                    self.facts.deinit(self.allocator);
                    self.controller_values.deinit(self.allocator);
                    self.observer_successors.deinit();
                }
            };
        }
        pub fn validateWorkspaceWorkSnapshotIn(
            self: *Self,
            parent: state.Task,
            snapshot: workspace.WorkObservation,
            records: []const state.ArchiveRecord,
            checked: *SnapshotValidation,
        ) anyerror!void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const bytes = try contracts.encodeOwned(workspace.WorkObservation, a, snapshot);
            defer a.free(bytes);
            const key: SnapshotValidation.Key = .{
                .kind = .snapshot,
                .task = parent.id,
                .identity = storage.digest(bytes),
            };
            if (checked.facts.get(
                key,
            )) |prior| return if (prior == .checked) {} else error.InvalidArchive;
            try checked.facts.put(checked.allocator, key, .visiting);
            errdefer _ = checked.facts.remove(key);
            try validateWorkspaceWorkSnapshotBody(self, a, parent, snapshot, records, checked);
            checked.facts.getPtr(key).?.* = .checked;
        }
        fn validateWorkspaceWorkSnapshotBody(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            snapshot: workspace.WorkObservation,
            records: []const state.ArchiveRecord,
            checked: *SnapshotValidation,
        ) anyerror!void {
            var phase: []const u8 = "publication";
            errdefer std.debug.print("work snapshot: {s}\n", .{phase});
            const value = snapshot.work;
            try validateWorkspacePublication(self, a, parent.id, snapshot);
            phase = "guard";
            if (value.guard != null) try validateGuardSnapshot(self, a, snapshot, records);
            phase = "current work and observer";
            // A checkpoint certifies execution, not native custody facts. Those
            // facts either remain immutable or grow monotonically in the owner.
            var current = try self.workspaceWork(a, parent.id, value.id);
            defer current.deinit();
            try validateSnapshotCurrent(self, a, parent, value, current.value, checked);
            try validateSnapshotRuntime(self, a, parent, value, records, &phase);
            phase = "inputs";
            try validateWorkspaceInputs(self, a, value);
            try validateSnapshotProgress(parent, value, current.value);
            var program = try self.workspaceProgram(a, parent.id, value.program);
            defer program.deinit();
            try validateSnapshotTrial(
                self,
                a,
                parent,
                value,
                current.value,
                program.value,
                records,
                checked,
            );
            const native_program = program.value.description.source_kind == .instrument_model or
                program.value.description.source_kind == .instrument_snapshot;
            try validateSnapshotDelegationInputs(
                self,
                a,
                parent,
                value,
                program.value,
                native_program,
                records,
                checked,
            );
            try validateSnapshotExecution(
                self,
                a,
                parent,
                value,
                program.value,
                native_program,
                checked,
            );
        }
        fn validateWorkspaceInstrumentAnswer(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            child: workspace.Work,
        ) !void {
            if (child.outcome_kind != .completed) {
                if (child.answer_value != null) return error.InvalidArchive;
                return;
            }
            var pending = try record(
                self,
                occurrence.Occurrence,
                a,
                "occurrence",
                child.instrument_occurrence orelse return error.InvalidArchive,
                parent.id,
            );
            defer pending.deinit();
            if (!std.meta.eql(pending.value.work, child.id) or pending.value.state != .admitted or
                pending.value.state.admitted != .reply)
                return error.InvalidArchive;
            const admitted = pending.value.state.admitted.reply;
            var reply = try data.invocation.decode(
                data.invocation.Result,
                a,
                try store(self).acquiredObject(a, admitted.reply, null),
            );
            defer reply.deinit();
            if (!std.meta.eql(reply.value.request_identity, pending.value.request) or
                !std.meta.eql(
                    child.result,
                    @as(?state.Reference, .{
                        .digest = storage.digest(reply.value.value),
                        .bytes = reply.value.value.len,
                    }),
                )) return error.InvalidArchive;
            var output = try contracts.decodeOwned(instrument.Output, a, reply.value.value);
            defer output.deinit();
            if (output.value == .unavailable) {
                if (child.answer_value != null) return error.InvalidArchive;
                return;
            }
            try validateInstrumentAnswerValue(self, a, parent, child, output.value, admitted);
        }
        pub fn validateCapsuleProvenance(
            work: workspace.Work,
            record_value: kosmos.RuntimeCapsule.Record,
        ) !void {
            if (!std.meta.eql(record_value.provenance.execution, work.id) or
                !std.meta.eql(record_value.provenance.custody, storage.digest(&work.task)) or
                record_value.provenance.publication == null or !std.meta.eql(
                record_value.provenance.publication.?.digest,
                work.checkpoint.digest,
            ) or
                record_value.provenance.publication.?.bytes != work.checkpoint.bytes)
                return error.InvalidArchive;
        }
        fn validateCapsuleObservation(
            candidate: anytype,
            selected: anytype,
            expected: kosmos.RuntimeInstrumentation.Output,
        ) !void {
            // Re-run only the source observer on a private candidate. A
            // zero-quantum advance does not perform a guest transition.
            if (!std.meta.eql(expected.source, selected.content.value.manifest.source) or
                !std.meta.eql(expected.realization, selected.identity) or
                !std.meta.eql(expected.guest, candidate.guest.admitted().identity()) or
                expected.guest_revision != candidate.guest_revision)
                return error.InvalidArchive;
            var observation =
                try candidate.exchange(.{ .advance = .{
                    .control = .none,
                    .quantum = 0,
                } });
            defer observation.deinit();
            if (observation.value != .cut or
                observation.value.cut.guest_work != 0 or
                !std.meta.eql(
                    observation.value.cut.trace,
                    @as(?kosmos.RuntimeInstrumentation.Trace, expected.trace),
                )) return error.InvalidArchive;
        }
        fn validateDelegationSelection(
            a: std.mem.Allocator,
            value: workspace.Delegation,
            authorized: workspace.Authorized,
        ) !void {
            const selection = authorized.command.work.delegate;
            if (selection.interpretation == .none or !same(
                try contracts.encodeOwned(wc.Interpretation, a, selection.interpretation),
                try contracts.encodeOwned(wc.Interpretation, a, value.selection),
            ) or
                !std.meta.eql(try wp.identity(selection.expected.work, .work), value.work) or
                (std.math.add(u64, selection.expected.control_revision, 1) catch
                    return error.InvalidArchive) != value.control_revision)
                return error.InvalidArchive;
            if (!same(
                try contracts.encodeOwned(?workspace.ModelBinding, a, authorized.model),
                try contracts.encodeOwned(?workspace.ModelBinding, a, value.model),
            )) return error.InvalidArchive;
            if (!std.meta.eql(
                if (value.selection == .snapshot) authorized.snapshot else null,
                value.snapshot,
            )) return error.InvalidArchive;
        }
        fn validateDelegatedPort(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            value: workspace.Delegation,
            selection: anytype,
        ) !void {
            var port = try contracts.decodeOwned(
                workspace.Port,
                a,
                try store(self).object(a, value.port, null),
            );
            defer port.deinit();
            const selected_port = switch (selection.interpretation) {
                .model => |v| v.port,
                .snapshot => |v| v.port,
                .none => unreachable,
            };
            const generation = switch (selection.interpretation) {
                .model => |v| v.generation,
                .snapshot => |v| v.generation,
                .none => unreachable,
            };
            if (!std.meta.eql(port.value.task, parent.id) or
                !std.meta.eql(port.value.work, value.work) or
                !std.meta.eql(port.value.program, value.program) or
                !std.meta.eql(port.value.id, try wp.identity(selected_port, .port)) or
                port.value.generation != generation) return error.InvalidArchive;
        }
        fn validateDelegatedChild(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            row: state.ArchiveRecord,
            value: workspace.Delegation,
            selection: anytype,
        ) !void {
            var child = try self.workspaceWork(a, parent.id, value.instrument);
            defer child.deinit();
            if (!std.meta.eql(child.value.delegation, row.body) or
                !std.meta.eql(child.value.origin_work, value.work)) return error.InvalidArchive;
            var program = try self.workspaceProgram(a, parent.id, child.value.program);
            defer program.deinit();
            if (program.value.description.source_kind != @as(
                @TypeOf(program.value.description.source_kind),
                if (value.selection == .model) .instrument_model else .instrument_snapshot,
            )) return error.InvalidArchive;
            var input = try contracts.decodeOwned(
                instrument.Input,
                a,
                try store(self).object(a, child.value.input, null),
            );
            defer input.deinit();
            if (!std.meta.eql(input.value.delegation, row.body)) return error.InvalidArchive;
            if (selection.interpretation == .model) {
                if (value.model == null or
                    selection.interpretation.model.inputs.items.len != value.inputs.items.len)
                    return error.InvalidArchive;
                const requested_inputs = selection.interpretation.model.inputs.items;
                for (requested_inputs, value.inputs.items) |ref, expected| {
                    const source = try workspaceValueReference(self, a, parent.id, ref);
                    if (!std.meta.eql(source.artifact, expected)) return error.InvalidArchive;
                }
            } else if (value.model != null or value.inputs.items.len != 0 or value.snapshot == null)
                return error.InvalidArchive;
        }
        pub fn validateCapsuleOperation(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            ref: state.Reference,
            trace: ?kosmos.RuntimeInstrumentation.Output,
            pending_operation: ?workspace.OuterOperation,
            record_value: kosmos.RuntimeCapsule.Record,
            command: anytype,
        ) !void {
            if (pending_operation) |pending| {
                if (trace != null or
                    record_value.operation != .advance or
                    record_value.kind != .outer_execution or
                    !std.meta.eql(ref, pending.capsule) or pending.guest_quantum > 256)
                    return error.InvalidArchive;
                try validateOuterControl(self, a, work, pending, command);
            } else if (record_value.operation != null) return error.InvalidArchive;
        }
        fn validateInstrumentAnswerValue(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            child: workspace.Work,
            output: instrument.Output,
            admitted: anytype,
        ) !void {
            const answer_ref = child.answer_value orelse return error.InvalidArchive;
            const answer = try workspaceValueReference(
                self,
                a,
                parent.id,
                try wp.reference(a, .value, answer_ref.digest),
            );
            const delegation_ref = child.delegation orelse return error.InvalidArchive;
            var delegation = try contracts.decodeOwned(
                workspace.Delegation,
                a,
                try store(self).object(a, delegation_ref, null),
            );
            defer delegation.deinit();
            var port = try contracts.decodeOwned(
                workspace.Port,
                a,
                try store(self).object(a, delegation.value.port, null),
            );
            defer port.deinit();
            if (!std.meta.eql(answer.artifact, answer_ref) or
                !std.meta.eql(answer.schema, port.value.interface.argument) or
                !std.meta.eql(answer.value, state.Reference{
                    .digest = storage.digest(output.answer.bytes),
                    .bytes = output.answer.bytes.len,
                })) return error.InvalidArchive;
            const expected: workspace.Derivation = switch (delegation.value.selection) {
                .snapshot => |selected| .{
                    .kind = .acquisition,
                    .sources = .{ .items = &.{} },
                    .acquisition = try workspaceSnapshotRange(
                        self,
                        a,
                        parent,
                        delegation.value.snapshot orelse return error.InvalidArchive,
                        selected,
                    ),
                },
                .model => blk: {
                    var capture_value =
                        try record(self, state.Capture, a, "capture", admitted.attempt, parent.id);
                    defer capture_value.deinit();
                    break :blk .{
                        .kind = .judgment,
                        .sources = delegation.value.inputs,
                        .work = child.id,
                        .delegation = delegation_ref,
                        .capture = capture_value.value.response orelse return error.InvalidArchive,
                    };
                },
                else => return error.InvalidArchive,
            };
            const provenance = try contracts.encodeOwned(workspace.Derivation, a, expected);
            if (!std.meta.eql(answer.provenance, state.Reference{
                .digest = storage.digest(provenance),
                .bytes = provenance.len,
            })) return error.InvalidArchive;
        }
        pub fn validateBindingSuccession(
            self: *Self,
            frame: std.mem.Allocator,
            task_id: state.TaskId,
            records: []const state.ArchiveRecord,
            binding: anytype,
        ) !void {
            var matching: usize = 0;
            for (records) |row| if (row.kind == .controller_succession) {
                var operation_value = try record(
                    self,
                    state.ControllerSuccession,
                    frame,
                    "controller_succession",
                    row.id,
                    task_id,
                );
                defer operation_value.deinit();
                if (operation_value.value.phase == .activated and
                    operation_value.value.activation_event == binding.activated_at and
                    operation_value.value.activated_epoch == binding.epoch and
                    std.meta.eql(operation_value.value.predecessor, binding.predecessor.?) and
                    std.meta.eql(operation_value.value.successor, binding.program)) matching += 1;
            };
            if (matching != 1) return error.InvalidArchive;
        }
        pub fn selectCapsuleRuntime(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            runtime_ref: state.Reference,
            expected_runtime: ?state.Reference,
            image: []const u8,
        ) !kosmos.RuntimeArtifact {
            return if (expected_runtime) |expected| chosen: {
                if (!std.meta.eql(runtime_ref, expected)) return error.InvalidArchive;
                var owned = try workspaceRuntime(self, a, work.task, expected.digest, work.program);
                defer owned.deinit();
                if (!std.meta.eql(owned.record.value.artifact, expected))
                    return error.InvalidArchive;
                break :chosen try owned.admitted.clone();
            } else chosen: {
                var packaged = try self.program.prepare(a, image);
                defer packaged.deinit();
                if (!std.meta.eql(runtime_ref.digest, packaged.runtime.identity) or
                    runtime_ref.bytes != packaged.runtime.core.?.encoded_length)
                    return error.InvalidArchive;
                break :chosen try packaged.runtime.clone();
            };
        }
        fn validateSnapshotCurrent(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            value: workspace.Work,
            current: workspace.Work,
            checked: *SnapshotValidation,
        ) !void {
            try validateObserver(self, a, value, &checked.observer_successors);
            if (value.observer != null and !parent.observers_present) return error.InvalidArchive;
            inline for (.{
                "version",
                "program",
                "input",
                "input_value",
                "origin_work",
                "delegation",
                "trial",
            }) |field|
                if (!std.meta.eql(@field(value, field), @field(current, field)))
                    return error.InvalidArchive;
            inline for (.{
                "execution_revision",
                "control_revision",
                "realization_revision",
                "port_generation",
                "event_watermark",
            }) |field|
                if (@field(value, field) > @field(current, field))
                    return error.InvalidArchive;
            if (value.realization_revision == current.realization_revision and
                !std.meta.eql(value.runtime, current.runtime)) return error.InvalidArchive;
        }
        fn validateSnapshotRuntime(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            value: workspace.Work,
            records: []const state.ArchiveRecord,
            phase: *[]const u8,
        ) !void {
            if (value.runtime) |ref| {
                phase.* = "selected runtime";
                var selected =
                    try workspaceRuntime(self, a, parent.id, ref.digest, value.program);
                defer selected.deinit();
                if (!std.meta.eql(ref, selected.record.value.artifact)) return error.InvalidArchive;
                try requireArchiveRecord(records, .workspace_runtime, selected.record.value.id);
            }
            if (value.outer_operation) |pending| {
                phase.* = "outer operation";
                try validatePublishedCapsuleTrace(
                    self,
                    a,
                    value,
                    pending.capsule,
                    value.runtime,
                    null,
                    pending,
                );
                const capsule_bytes = try store(self).object(a, pending.capsule, null);
                defer a.free(capsule_bytes);
                const dependencies = try capsuleDependencies(a, capsule_bytes);
                defer a.free(dependencies);
                if (dependencies.len != pending.dependencies.items.len) return error.InvalidArchive;
                for (dependencies, pending.dependencies.items) |wanted, actual|
                    if (!std.meta.eql(wanted, actual)) return error.InvalidArchive;
            }
            if (value.runtime_capsule) |ref| {
                phase.* = "runtime capsule";
                if (value.outer_operation) |pending| {
                    if (!std.meta.eql(ref, pending.capsule)) return error.InvalidArchive;
                } else try validatePublishedCapsule(self, a, value, ref, value.runtime);
                const capsule_bytes = try store(self).object(a, ref, null);
                defer a.free(capsule_bytes);
                const dependencies = try capsuleDependencies(a, capsule_bytes);
                defer a.free(dependencies);
                if (dependencies.len != value.runtime_dependencies.items.len)
                    return error.InvalidArchive;
                for (dependencies, value.runtime_dependencies.items) |wanted, actual|
                    if (!std.meta.eql(wanted, actual)) return error.InvalidArchive;
            } else if (value.runtime_dependencies.items.len != 0) return error.InvalidArchive;
            if (value.runtime_trace) |trace| {
                phase.* = "runtime trace";
                try validatePublishedCapsuleTrace(
                    self,
                    a,
                    value,
                    trace.capsule,
                    value.runtime,
                    trace.output,
                    null,
                );
                const bytes = try store(self).object(a, trace.capsule, null);
                defer a.free(bytes);
                const dependencies = try capsuleDependencies(a, bytes);
                defer a.free(dependencies);
                if (dependencies.len != trace.dependencies.items.len) return error.InvalidArchive;
                for (dependencies, trace.dependencies.items) |wanted, actual|
                    if (!std.meta.eql(wanted, actual)) return error.InvalidArchive;
            }
        }
        fn validateSnapshotProgress(
            parent: state.Task,
            value: workspace.Work,
            current: workspace.Work,
        ) !void {
            inline for (.{
                "result",
                "result_value",
                "answer_value",
                "instrument_occurrence",
            }) |field| {
                if (@field(value, field) != null and !std.meta.eql(
                    @field(value, field),
                    @field(current, field),
                )) return error.InvalidArchive;
            }
            if (value.cancellation) |reason| {
                const actual = current.cancellation orelse return error.InvalidArchive;
                if (!same(reason.bytes, actual.bytes)) return error.InvalidArchive;
            }
            if (value.cancellation_applied and !current.cancellation_applied)
                return error.InvalidArchive;
            if (value.terminal() and value.execution_revision != current.execution_revision)
                return error.InvalidArchive;
            if (value.execution_revision == current.execution_revision) {
                inline for (.{
                    "checkpoint",
                    "outcome",
                    "outcome_kind",
                    "current_occurrence",
                    "current_port",
                    "port_generation",
                    "result",
                    "result_value",
                    "answer_value",
                    "guest_work",
                }) |field|
                    if (!std.meta.eql(@field(value, field), @field(current, field)))
                        return error.InvalidArchive;
            }
            if (value.execution_revision == 0 or
                value.control_revision == 0 or
                value.event_watermark > parent.event_high or
                (value.cancellation_applied and value.cancellation == null))
                return error.InvalidArchive;
        }
        fn validateSnapshotTrial(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            value: workspace.Work,
            current: workspace.Work,
            program: workspace.Program,
            records: []const state.ArchiveRecord,
            checked: *SnapshotValidation,
        ) !void {
            if ((program.description.controller != null) != (value.trial != null))
                return error.InvalidArchive;
            if (value.trial) |id| {
                if (!std.meta.eql(id, value.id) or !std.meta.eql(value.trial, current.trial))
                    return error.InvalidArchive;
                try requireArchiveRecord(records, .workspace_trial, id);
                var trial =
                    try record(self, workspace.Trial, a, "workspace_trial", id, parent.id);
                defer trial.deinit();
                if (trial.value.selection != .synthetic or
                    trial.value.responses.items.len !=
                        trial.value.selection.synthetic.responses.items.len or
                    value.inputs.items.len != trial.value.responses.items.len * 2 or
                    !std.meta.eql(trial.value.policy, parent.profile)) return error.InvalidArchive;
                var view = try contracts.decodeOwned(
                    contracts.controller.OwnerView,
                    a,
                    try store(self).object(a, trial.value.view, null),
                );
                defer view.deinit();
                if (!std.meta.eql(view.value.task, parent.id) or
                    view.value.event_cut >= value.event_watermark or !std.meta.eql(
                    view.value.policy,
                    parent.profile.digest,
                )) return error.InvalidArchive;
                try validateControllerViewIn(
                    self,
                    a,
                    parent,
                    view.value,
                    trial.value.view_works.items,
                    records,
                    checked,
                );
                try validateTrialResponses(self, a, parent, value, trial.value, checked);
            }
        }
        fn validateSnapshotDelegationInputs(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            value: workspace.Work,
            program: workspace.Program,
            native_program: bool,
            records: []const state.ArchiveRecord,
            checked: *SnapshotValidation,
        ) !void {
            if (native_program != (value.delegation != null) or (value.delegation == null and
                (value.answer_value != null or value.instrument_occurrence != null)))
                return error.InvalidArchive;
            if (value.delegation) |ref| {
                var delegation = try contracts.decodeOwned(
                    workspace.Delegation,
                    a,
                    try store(self).object(a, ref, null),
                );
                defer delegation.deinit();
                try requireArchiveRecord(records, .workspace_delegation, delegation.value.id);
                if (!std.meta.eql(delegation.value.instrument, value.id))
                    return error.InvalidArchive;
                if (value.instrument_occurrence) |id| try requireArchiveRecord(
                    records,
                    .occurrence,
                    id,
                );
            }
            const input = try workspaceValueReferenceIn(
                self,
                a,
                parent.id,
                try wp.reference(a, .value, (value.input_value orelse
                    return error.InvalidArchive).digest),
                checked,
            );
            if (!std.meta.eql(input.value, value.input) or !std.meta.eql(
                input.schema,
                program.description.input_schema,
            )) return error.InvalidArchive;
            for (value.inputs.items) |ref| _ = try workspaceValueReferenceIn(
                self,
                a,
                parent.id,
                try wp.reference(a, .value, ref.digest),
                checked,
            );
        }
        fn validateSnapshotExecution(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            value: workspace.Work,
            program: workspace.Program,
            native_program: bool,
            checked: *SnapshotValidation,
        ) !void {
            var prepared = try inspectionRuntime(self, self.allocator, value);
            defer prepared.deinit();
            const checkpoint = try store(self).object(a, value.checkpoint, null);
            defer a.free(checkpoint);
            var candidate = try kosmos.Session.restore(self.allocator, &prepared, checkpoint);
            defer candidate.deinit();
            var finished = try kosmos.invocation.finishPublication(a, &candidate, .receipt, null);
            defer finished.outcome.deinit();
            defer self.allocator.free(finished.checkpoint.?);
            try validateGuardAgreement(self, a, value, &candidate);
            const publication = .{
                .outcome = try data.invocation.encodeOwned(
                    data.invocation.Outcome,
                    a,
                    finished.outcome.record,
                ),
                .checkpoint = finished.checkpoint.?,
            };
            defer a.free(publication.outcome);
            if (!std.meta.eql(storage.digest(publication.outcome), value.outcome.digest) or
                publication.outcome.len != value.outcome.bytes or
                !std.meta.eql(storage.digest(publication.checkpoint), value.checkpoint.digest) or
                publication.checkpoint.len != value.checkpoint.bytes)
                return error.InvalidArchive;
            var observed =
                try data.invocation.decode(data.invocation.Outcome, a, publication.outcome);
            defer observed.deinit();
            if (!same(@tagName(observed.value), @tagName(value.outcome_kind)))
                return error.InvalidArchive;
            try validateCancellation(a, value, observed.value, publication.checkpoint);
            try validateSnapshotOutcome(self, a, parent, value, program, observed.value, checked);

            if (observed.value != .requested and
                (value.current_occurrence != null or value.current_port != null))
                return error.InvalidArchive;
            if (native_program) try validateWorkspaceInstrumentAnswer(self, a, parent, value);
        }
        fn validateSnapshotOutcome(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            value: workspace.Work,
            program: workspace.Program,
            observed: data.invocation.Outcome,
            checked: *SnapshotValidation,
        ) !void {
            switch (observed) {
                .requested => |pending| {
                    const id = value.current_occurrence orelse return error.InvalidArchive;
                    var occurrence_value =
                        try record(self, occurrence.Occurrence, a, "occurrence", id, parent.id);
                    defer occurrence_value.deinit();
                    if (!std.meta.eql(occurrence_value.value.request_object, state.Reference{
                        .digest = storage.digest(pending.request),
                        .bytes = pending.request.len,
                    })) return error.InvalidArchive;
                    var route = try record(
                        self,
                        workspace.ExecutionRoute,
                        a,
                        "execution_route",
                        id,
                        parent.id,
                    );
                    defer route.deinit();
                    if (!std.meta.eql(value.current_port, route.value.port))
                        return error.InvalidArchive;
                },
                .completed => |bytes| try validateSnapshotResult(
                    self,
                    a,
                    parent,
                    value,
                    program,
                    bytes,
                    checked,
                ),
                else => if (value.result != null or value.result_value != null)
                    return error.InvalidArchive,
            }
        }
        fn validateTrialResponses(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            value: workspace.Work,
            trial: workspace.Trial,
            checked: *SnapshotValidation,
        ) !void {
            const selected_responses = trial.selection.synthetic.responses.items;
            for (selected_responses, trial.responses.items, 0..) |selection, response, i| {
                if (!same(selection.identity.bytes, response.identity.bytes) or !std.meta.eql(
                    (try workspaceValueReferenceIn(
                        self,
                        a,
                        parent.id,
                        selection.payload,
                        checked,
                    )).artifact,
                    response.payload,
                ) or !std.meta.eql(
                    (try workspaceValueReferenceIn(
                        self,
                        a,
                        parent.id,
                        selection.response,
                        checked,
                    )).artifact,
                    response.response,
                ) or !std.meta.eql(value.inputs.items[i * 2], response.payload) or !std.meta.eql(
                    value.inputs.items[i * 2 + 1],
                    response.response,
                )) return error.InvalidArchive;
                const payload =
                    try workspaceValueReferenceIn(self, a, parent.id, selection.payload, checked);
                for (trial.selection.synthetic.responses.items[0..i]) |prior| {
                    if (!same(selection.identity.bytes, prior.identity.bytes)) continue;
                    const previous =
                        try workspaceValueReferenceIn(self, a, parent.id, prior.payload, checked);
                    if (std.meta.eql(payload.schema, previous.schema) and
                        std.meta.eql(payload.value, previous.value)) return error.InvalidArchive;
                }
            }
        }
        pub fn validateArchiveValueDerivation(
            self: *Self,
            frame: std.mem.Allocator,
            parent: state.Task,
            record_value: workspace.Value,
            admitted: anytype,
            records: []const state.ArchiveRecord,
            checked: *SnapshotValidation,
        ) !void {
            const task_id = parent.id;
            const derivation = record_value.derivation;
            if (derivation.inspection) |origin|
                try validateWorkspaceWorkSnapshotIn(
                    self,
                    parent,
                    origin.observation,
                    records,
                    checked,
                );
            if (derivation.semantic_source) |origin| {
                const request: wc.Command = .{ .program = .{ .inspect = .{
                    .target = .{ .semantic_source = .{
                        .subject = origin.selection.subject,
                        .section = .{ .summary = .{} },
                    } },
                    .page = .{},
                } } };
                try validateWorkspaceReadIn(
                    self,
                    frame,
                    parent,
                    request,
                    origin.basis,
                    records,
                    checked.controller_values.get(record_value.artifact.digest),
                    checked,
                );
            }
            if (derivation.kind == .computation or derivation.kind == .trial) {
                try validateComputedValueDerivation(self, frame, task_id, derivation, admitted);
            } else if (derivation.delegation != null) {
                try validateDelegatedValue(self, frame, task_id, record_value);
            } else if (derivation.program != null or derivation.work != null or
                derivation.capture != null)
                return error.InvalidArchive;
        }
        pub fn validateCapsuleCheckpoint(
            a: std.mem.Allocator,
            work: workspace.Work,
            candidate: anytype,
            selected: anytype,
            trace: ?kosmos.RuntimeInstrumentation.Output,
        ) !void {
            const checkpoint = try candidate.checkpoint(a);
            defer a.free(checkpoint);
            if (!std.meta.eql(storage.digest(checkpoint), work.checkpoint.digest) or
                checkpoint.len != work.checkpoint.bytes) return error.InvalidArchive;
            if (trace) |expected| try validateCapsuleObservation(candidate, selected, expected);
        }
        pub fn validateWaitSelection(
            self: *Self,
            frame: std.mem.Allocator,
            task_id: state.TaskId,
            wait: workspace.Wait,
            authorized: workspace.Authorized,
        ) !void {
            if (authorized.command != .work or authorized.command.work != .wait)
                return error.InvalidArchive;
            const expected = try contracts.encodeOwned(
                @TypeOf(wait.selection),
                frame,
                authorized.command.work.wait,
            );
            const actual =
                try contracts.encodeOwned(@TypeOf(wait.selection), frame, wait.selection);
            if (!same(actual, expected)) return error.InvalidArchive;
            for (wait.selection.works.items) |ref| {
                var work =
                    try self.workspaceWork(frame, task_id, try wp.identity(ref, .work));
                work.deinit();
            }
        }
        fn validateSnapshotResult(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            value: workspace.Work,
            program: workspace.Program,
            bytes: []const u8,
            checked: *SnapshotValidation,
        ) !void {
            if (value.result == null or value.result_value == null or !std.meta.eql(
                value.result.?,
                state.Reference{ .digest = storage.digest(bytes), .bytes = bytes.len },
            )) return error.InvalidArchive;
            const result = try workspaceValueReferenceIn(
                self,
                a,
                parent.id,
                try wp.reference(a, .value, value.result_value.?.digest),
                checked,
            );
            if (!std.meta.eql(result.artifact, value.result_value.?) or
                !std.meta.eql(result.value, value.result.?) or !std.meta.eql(
                result.schema,
                program.description.result_schema,
            )) return error.InvalidArchive;
            var retained = try record(
                self,
                workspace.Value,
                a,
                "workspace_value",
                try workspaceContentCustody(a, parent.id, result.artifact.digest),
                parent.id,
            );
            defer retained.deinit();
            const expected = try workspaceResultDerivation(self, a, value, program);
            if (!same(
                try contracts.encodeOwned(workspace.Derivation, a, expected),
                try contracts.encodeOwned(workspace.Derivation, a, retained.value.derivation),
            )) return error.InvalidArchive;
        }
        fn validateComputedValueDerivation(
            self: *Self,
            frame: std.mem.Allocator,
            task_id: state.TaskId,
            derivation: workspace.Derivation,
            admitted: anytype,
        ) !void {
            var work = try self.workspaceWork(frame, task_id, derivation.work orelse
                return error.InvalidArchive);
            defer work.deinit();
            var program = try self.workspaceProgram(frame, task_id, work.value.program);
            defer program.deinit();
            if ((derivation.kind == .trial) != (work.value.trial != null))
                return error.InvalidArchive;
            if (work.value.result_value == null or
                !std.meta.eql(work.value.result_value.?, admitted.artifact) or
                work.value.result == null or !std.meta.eql(work.value.result.?, admitted.value) or
                derivation.program == null or
                !std.meta.eql(derivation.program.?, program.value.artifact) or
                !std.meta.eql(admitted.schema, program.value.description.result_schema) or
                derivation.sources.items.len != work.value.inputs.items.len + 1 or
                work.value.input_value == null or
                !std.meta.eql(derivation.sources.items[0], work.value.input_value.?))
                return error.InvalidArchive;
            const derived_inputs = derivation.sources.items[1..];
            for (derived_inputs, work.value.inputs.items) |left, right|
                if (!std.meta.eql(left, right)) return error.InvalidArchive;
        }
    };
}
