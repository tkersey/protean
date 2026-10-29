const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const evaluator = @import("../driver.zig");
const kosmos = @import("kosmos");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const GuardOperation = task_types.GuardOperation;
const GuardRetention = task_types.GuardRetention;
const Work = task_types.Work;
const name = task_types.name;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const capsuleDependencies = Realization.capsuleDependencies;
        const replay = Records.replay;
        const requireArchiveRecord = Occurrences.requireArchiveRecord;
        const requireCustody = Lifecycle.requireCustody;
        const requireSemanticPolicy = Observations.requireSemanticPolicy;
        const retire = Lifecycle.retire;
        const runtimeWork = Programs.runtimeWork;
        const snapshotRecord = Records.snapshotRecord;
        const store = Lifecycle.store;
        const validatePublishedCapsuleTrace = Realization.validatePublishedCapsuleTrace;
        const workspaceCommit = Publication.workspaceCommit;
        const workspaceConsumed = Execution.workspaceConsumed;
        const workspaceFinish = Execution.workspaceFinish;
        const workspaceParentStopped = Access.workspaceParentStopped;
        const workspaceResident = Execution.workspaceResident;
        const writeWorkspaceWork = Publication.writeWorkspaceWork;
        const Occurrences = @import("archive_occurrences.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Execution = @import("workspace_execution.zig").Operations(Types, Self);
        const Observations = @import("workspace_observations.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Publication = @import("workspace_publication.zig").Operations(Types, Self);
        const Realization = @import("workspace_realization.zig").Operations(Types, Self);
        pub fn workspaceGuard(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            command: @FieldType(workspace.GuardRequest, "command"),
        ) !Admission {
            const request =
                try operation(workspace.GuardRequest, a, .{
                    .task = task_id,
                    .command = command,
                });
            if (try replay(self, a, operation_id, request)) |prior| return prior;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            if (command == .guard and workspaceParentStopped(self, parent.value))
                return error.InvalidState;
            const expected = switch (command) {
                inline else => |selection| selection.expected,
            };
            var work = try guardWork(self, a, task_id, expected, command == .guard);
            defer work.deinit();
            if (command == .guard and (work.value.terminal() or work.value.outer_operation != null))
                return error.GuestCutUnavailable;
            switch (command) {
                .guard => |selection| {
                    if (work.value.cancellation != null) return error.InvalidState;
                    if (work.value.guard != null) return error.GuardAlreadyActive;
                    if (selection.realization_revision != work.value.realization_revision)
                        return error.StaleRevision;
                    work.value.guard =
                        try workspaceGuardBinding(self, a, work.value, selection.candidate);
                },
                .unguard => |selection| {
                    const guard = work.value.guard orelse return error.GuardUnavailable;
                    if (selection.guard_revision != guard.revision) return error.StaleRevision;
                    work.value.guard = null;
                },
            }
            work.value.control_revision = try std.math.add(u64, work.value.control_revision, 1);
            work.value.event_watermark = try std.math.add(u64, parent.value.event_high, 1);
            try store(self).begin();
            defer store(self).rollback();
            const id = work.value.id;
            try writeWorkspaceWork(self, &work.value, .replace);
            const publication: workspace.PublicationCommand = switch (command) {
                .guard => |selection| .{ .guard = selection },
                .unguard => |selection| .{ .unguard = selection },
            };
            const snapshot =
                try snapshotRecord(self, workspace.Work, a, "workspace_work", id, task_id);
            return workspaceCommit(
                self,
                a,
                parent.value,
                operation_id,
                request,
                work.value.id,
                .work,
                snapshot,
                publication,
            );
        }
        fn guardWork(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            expected: wc.Expected,
            enabling: bool,
        ) !contracts.Decoded(workspace.Work) {
            if (enabling) return runtimeWork(self, a, task_id, expected);
            const id = try wp.identity(expected.work, .work);
            try requireCustody(self, a, task_id, id);
            var work = try self.workspaceWork(a, task_id, id);
            errdefer work.deinit();
            if (work.value.execution_revision != expected.execution_revision or
                work.value.control_revision != expected.control_revision)
                return error.StaleRevision;
            return work;
        }
        fn workspaceGuardBinding(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            candidate_ref: wc.Ref,
        ) !workspace.Guard {
            const policy = self.profile.semantic_construction orelse
                return error.SemanticPolicyDenied;
            if (!policy.guard) return error.GuardPolicyDenied;
            var candidate = try self.workspaceCandidate(
                a,
                work.task,
                try wp.identity(candidate_ref, .candidate),
            );
            defer candidate.deinit();
            const description = candidate.value.description;
            try requireSemanticPolicy(self, description.root, description.checker.bytes);
            var program = try self.workspaceProgram(a, work.task, work.program);
            defer program.deinit();
            if (!std.meta.eql(program.value.description.image, description.guest))
                return error.GuestIdentityMismatch;
            return initialGuard(candidate.value.artifact, description.code);
        }
        fn initialGuard(candidate: state.Reference, code: state.Reference) workspace.Guard {
            return .{ .candidate = candidate, .code = code, .revision = 0 };
        }
        pub fn runtimeProvenance(work: workspace.Work) kosmos.RuntimeCapsule.Provenance {
            return .{ .execution = work.id, .custody = storage.digest(&work.task), .publication = .{
                .digest = work.checkpoint.digest,
                .bytes = work.checkpoint.bytes,
            } };
        }
        pub fn validateGuardSelection(
            item: state.WorkPublication,
            prior: state.WorkPublication,
            command: workspace.PublicationCommand,
        ) !void {
            const expected = switch (command) {
                .guard => |selection| selection.expected,
                .unguard => |selection| selection.expected,
                else => return error.InvalidArchive,
            };
            if (!std.meta.eql(try wp.identity(expected.work, .work), item.work) or
                expected.execution_revision != prior.execution_revision or
                expected.control_revision != prior.control_revision or
                item.execution_revision != prior.execution_revision or
                item.control_revision -| prior.control_revision != 1 or
                item.control.delivery != prior.control.delivery)
                return error.InvalidArchive;
            switch (command) {
                .guard => |selection| {
                    const guard = item.guard orelse return error.InvalidArchive;
                    if (item.control.delivery == .dispatching or item.control.delivery == .unknown)
                        return error.InvalidArchive;
                    if (prior.guard != null or
                        !equalGuards(guard, initialGuard(guard.candidate, guard.code)) or
                        selection.realization_revision != prior.realization_revision or
                        !std.meta.eql(
                            try wp.identity(selection.candidate, .candidate),
                            guard.candidate.digest,
                        )) return error.InvalidArchive;
                },
                .unguard => |selection| {
                    const guard = prior.guard orelse return error.InvalidArchive;
                    if (item.guard != null or selection.guard_revision != guard.revision)
                        return error.InvalidArchive;
                },
                else => unreachable,
            }
        }
        pub fn guardProgress(item: state.WorkPublication, prior: state.WorkPublication) bool {
            const next = item.guard orelse return false;
            const before = prior.guard orelse return false;
            return next.revision > before.revision and
                item.execution_revision == prior.execution_revision;
        }
        pub fn guardSchedule(guard: workspace.Guard, policy: workspace.RunPolicy) state.Schedule {
            return if (guard.disposition == .diverged or guard.failure != null or
                policy.continuation == .explicit_only) .parked else .queued;
        }
        pub fn validateGuardProgress(
            item: state.WorkPublication,
            prior: ?state.WorkPublication,
            command: ?workspace.PublicationCommand,
        ) !void {
            if (command) |selected| if (selected == .guard or selected == .unguard) return;
            const before = prior orelse {
                if (item.guard != null) return error.InvalidArchive;
                return;
            };
            if (equalGuards(item.guard, before.guard)) {
                if (item.guard != null and item.execution_revision != before.execution_revision)
                    return error.InvalidArchive;
                return;
            }
            if (item.control.cancellation != null and item.guard == null) return;
            const old = before.guard orelse return error.InvalidArchive;
            const next = item.guard orelse return error.InvalidArchive;
            if (next.revision -| old.revision != 1 or
                !std.meta.eql(next.candidate, old.candidate) or
                !std.meta.eql(next.code, old.code) or
                next.reference_nanoseconds < old.reference_nanoseconds or
                next.candidate_nanoseconds < old.candidate_nanoseconds)
                return error.InvalidArchive;
            if (item.execution_revision != before.execution_revision) {
                if (next.disposition != .agreed or next.pending_control != null or
                    next.reference_operation != null or next.candidate_segment != null or
                    next.agreed_segments -| old.agreed_segments != 1 or !next.initialized)
                    return error.InvalidArchive;
            } else {
                if ((next.disposition != .incomplete and next.disposition != .diverged) or
                    next.pending_control == null or next.agreed_segments != old.agreed_segments)
                    return error.InvalidArchive;
                if (old.pending_control) |ref|
                    if (!std.meta.eql(ref, next.pending_control.?)) return error.InvalidArchive;
            }
        }
        fn equalGuards(left: ?workspace.Guard, right: ?workspace.Guard) bool {
            var lhs = left orelse return right == null;
            var rhs = right orelse return false;
            if ((lhs.failure == null) != (rhs.failure == null)) return false;
            if (lhs.failure) |failure| if (!same(failure.bytes, rhs.failure.?.bytes)) return false;
            if ((lhs.reference_operation == null) != (rhs.reference_operation == null))
                return false;
            if (lhs.reference_operation) |*pending| {
                const other = &rhs.reference_operation.?;
                if (!std.meta.eql(pending.capsule, other.capsule) or
                    !std.meta.eql(pending.control, other.control) or
                    pending.guest_quantum != other.guest_quantum or
                    pending.dependencies.items.len != other.dependencies.items.len) return false;
                for (pending.dependencies.items, other.dependencies.items) |left_ref, right_ref|
                    if (!std.meta.eql(left_ref, right_ref)) return false;
                lhs.reference_operation = null;
                rhs.reference_operation = null;
            }
            lhs.failure = null;
            rhs.failure = null;
            return std.meta.eql(lhs, rhs);
        }
        pub fn validateGuardSnapshot(
            self: *Self,
            a: std.mem.Allocator,
            snapshot: workspace.WorkObservation,
            records: []const state.ArchiveRecord,
        ) !void {
            var phase: []const u8 = "candidate";
            errdefer std.debug.print("guard snapshot: {s}\n", .{phase});
            const work = snapshot.work;
            const guard = work.guard orelse return error.InvalidArchive;
            if (work.outer_operation != null or work.cancellation != null)
                return error.InvalidArchive;
            var candidate =
                try self.workspaceCandidate(a, work.task, guard.candidate.digest);
            defer candidate.deinit();
            if (!std.meta.eql(candidate.value.artifact, guard.candidate) or
                !std.meta.eql(candidate.value.description.code, guard.code))
                return error.InvalidArchive;
            var current = try self.workspaceWork(a, work.task, work.id);
            defer current.deinit();
            if (current.value.guard) |active|
                if (std.meta.eql(active.candidate, guard.candidate))
                    try requireGuardPolicy(self, a, current.value);
            try requireArchiveRecord(records, .workspace_candidate, candidate.value.id);
            var program = try self.workspaceProgram(a, work.task, work.program);
            defer program.deinit();
            if (!std.meta.eql(candidate.value.description.guest, program.value.description.image))
                return error.InvalidArchive;
            if (guard.initialized and guard.continuation == null) return error.InvalidArchive;
            if (guard.continuation != null and guard.disposition != .agreed) {
                phase = "candidate continuation";
                var candidate_execution = try workspaceGuardExperiment(self, a, work);
                defer candidate_execution.deinit();
                if (guard.initialized != (candidate_execution.stage == .advanced))
                    return error.InvalidArchive;
            }
            phase = "reference";
            try validateGuardReference(self, a, work);
            phase = "pending control";
            if (guard.pending_control) |ref| {
                const bytes = try store(self).object(a, ref, null);
                defer a.free(bytes);
                var control = try contracts.decodeOwned(data.invocation.Control, a, bytes);
                defer control.deinit();
                try validateGuardControl(snapshot, control.value);
                if (guard.guest_quantum != 1 and guard.guest_quantum != 256)
                    return error.InvalidArchive;
            } else if (guard.disposition == .incomplete or guard.disposition == .diverged)
                return error.InvalidArchive;
        }
        pub fn validateGuardAgreement(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            reference: *kosmos.Session,
        ) !void {
            const guard = work.guard orelse return;
            if (guard.disposition != .agreed) return;
            if (!guard.initialized or guard.continuation == null) return error.InvalidArchive;
            var candidate = try workspaceGuardExperiment(self, a, work);
            defer candidate.deinit();
            if (candidate.stage != .advanced or candidate.phase != .ready)
                return error.InvalidArchive;
            var completed = try candidate.completedSegment(a);
            defer completed.deinit();
            const observation =
                if (reference.view) |view|
                    view.event.value.observation
                else
                    .progressed;
            const expected = try contracts.encodeOwned(@TypeOf(observation), a, observation);
            defer a.free(expected);
            if (!std.meta.eql(storage.digest(completed.checkpoint), work.checkpoint.digest) or
                completed.checkpoint.len != work.checkpoint.bytes or
                completed.guest_work != work.guest_work or !same(completed.observation, expected))
                return error.InvalidArchive;
        }
        fn validateGuardReference(self: *Self, a: std.mem.Allocator, work: workspace.Work) !void {
            const guard = work.guard.?;
            if (guard.candidate_segment) |segment| {
                if (!guard.initialized or
                    guard.pending_control == null or
                    guard.continuation == null or
                    (guard.disposition != .incomplete and guard.disposition != .diverged))
                    return error.InvalidArchive;
                var candidate = try workspaceGuardExperiment(self, a, work);
                defer candidate.deinit();
                if (candidate.phase != .ready or candidate.stage != .advanced or
                    candidate.guest_work != segment.guest_work) return error.InvalidArchive;
                const checkpoint = try store(self).object(a, segment.checkpoint, null);
                defer a.free(checkpoint);
                const observation = try store(self).object(a, segment.observation, null);
                defer a.free(observation);
                var completed = try candidate.completedSegment(a);
                defer completed.deinit();
                if (!same(checkpoint, completed.checkpoint) or
                    !same(observation, completed.observation) or
                    segment.guest_work != completed.guest_work) return error.InvalidArchive;
            }
            if (guard.reference_operation) |pending| {
                if (guard.candidate_segment == null or guard.pending_control == null or
                    !std.meta.eql(pending.control, guard.pending_control.?) or
                    pending.guest_quantum != guard.guest_quantum) return error.InvalidArchive;
                const bytes = try store(self).object(a, pending.capsule, null);
                defer a.free(bytes);
                const dependencies = try capsuleDependencies(a, bytes);
                defer a.free(dependencies);
                if (dependencies.len != pending.dependencies.items.len) return error.InvalidArchive;
                for (dependencies, pending.dependencies.items) |wanted, actual|
                    if (!std.meta.eql(wanted, actual)) return error.InvalidArchive;
                try validatePublishedCapsuleTrace(
                    self,
                    a,
                    work,
                    pending.capsule,
                    work.runtime,
                    null,
                    pending,
                );
            }
        }
        fn validateGuardControl(
            snapshot: workspace.WorkObservation,
            control: data.invocation.Control,
        ) !void {
            switch (control) {
                .reply => |reply| {
                    const pending = snapshot.occurrence orelse return error.InvalidArchive;
                    if (pending.state != .settled_reply) return error.InvalidArchive;
                    const expected = pending.state.settled_reply.reply;
                    if (!std.meta.eql(expected, storage.digest(reply))) return error.InvalidArchive;
                },
                .resume_yield => if (snapshot.work.outcome_kind != .yielded)
                    return error.InvalidArchive,
                .none => if (snapshot.work.current_occurrence != null or
                    snapshot.work.outcome_kind == .yielded) return error.InvalidArchive,
                .cancel => return error.InvalidArchive,
            }
        }
        fn requireGuardPolicy(self: *Self, a: std.mem.Allocator, work: workspace.Work) !void {
            const guard = work.guard orelse return error.GuardUnavailable;
            const policy = self.profile.semantic_construction orelse return error.GuardPolicyDenied;
            if (!policy.guard) return error.GuardPolicyDenied;
            var candidate =
                try self.workspaceCandidate(a, work.task, guard.candidate.digest);
            defer candidate.deinit();
            try requireSemanticPolicy(
                self,
                candidate.value.description.root,
                candidate.value.description.checker.bytes,
            );
        }
        fn workspaceGuardExperiment(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
        ) !kosmos.RuntimeExperiment.Experiment {
            var phase: []const u8 = "program";
            errdefer std.debug.print("guard experiment: {s}\n", .{phase});
            const guard = work.guard orelse return error.GuardUnavailable;
            var program = try self.workspaceProgram(a, work.task, work.program);
            defer program.deinit();
            const image =
                try store(self).object(a, program.value.description.image, null);
            defer a.free(image);
            const code = try store(self).object(a, guard.code, null);
            defer a.free(code);
            phase = "candidate artifact admission";
            var candidate = try kosmos.RuntimeArtifact.init(a, code, guard.code.digest);
            defer candidate.deinit();
            phase = "continuation bytes";
            const ref = guard.continuation orelse work.checkpoint;
            const bytes = try store(self).object(a, ref, null);
            defer a.free(bytes);
            phase = "continuation restore";
            if (guard.continuation != null)
                return kosmos.RuntimeExperiment.Experiment.restore(a, image, &candidate, bytes);
            phase = "initial experiment";
            return kosmos.RuntimeExperiment.Experiment.init(a, image, &candidate, bytes);
        }
        fn workspaceGuardCandidateAdvance(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: workspace.Work,
            control: data.invocation.Control,
            bytes: []const u8,
            base_quantum: u64,
            operation_value: GuardOperation,
        ) !Admission {
            var work = initial;
            const guard = &work.guard.?;
            var candidate = workspaceGuardExperiment(self, a, work) catch |err|
                return workspaceGuardFailure(self, a, parent, work, bytes, err, operation_value);
            defer candidate.deinit();
            if (guard.initialized and candidate.phase == .ready)
                try beginGuardCandidate(a, &candidate, control, guard.guest_quantum);
            const started = std.Io.Clock.awake.now(self.io);
            var progress = candidate.pump(base_quantum) catch |err|
                return workspaceGuardFailure(self, a, parent, work, bytes, err, operation_value);
            defer if (progress == .complete) progress.complete.deinit();
            guard.candidate_nanoseconds +|= std.math.cast(u64, @max(
                0,
                std.Io.Clock.awake.now(self.io).nanoseconds - started.nanoseconds,
            )) orelse std.math.maxInt(u64);
            guard.failure = null;
            if (progress == .complete and progress.complete.stage == .initialized) {
                if (!try guardInitialMatches(self, a, work, progress.complete))
                    return workspaceGuardDiverged(
                        self,
                        a,
                        parent,
                        work,
                        bytes,
                        &candidate,
                        operation_value,
                    );
                guard.initialized = true;
                try beginGuardCandidate(a, &candidate, control, guard.guest_quantum);
            } else if (progress == .complete) {
                const capsule = try candidate.checkpointOuter(a);
                defer a.free(capsule);
                guard.disposition = .incomplete;
                return workspaceGuardRetain(self, a, parent, work, bytes, .{
                    .candidate = capsule,
                    .segment = progress.complete,
                }, operation_value);
            }
            const capsule = try candidate.checkpointOuter(a);
            defer a.free(capsule);
            guard.disposition = .incomplete;
            return workspaceGuardRetain(
                self,
                a,
                parent,
                work,
                bytes,
                .{ .candidate = capsule },
                operation_value,
            );
        }
        pub fn workspaceGuardAdvance(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: workspace.Work,
            control: data.invocation.Control,
            quantum: u64,
            base_quantum: u64,
            operation_id: ?[]const u8,
            request: state.Digest,
            command: ?workspace.PublicationCommand,
        ) !Admission {
            const operation_value: GuardOperation = .{
                .operation_id = operation_id,
                .request = request,
                .command = command,
            };
            var work = initial;
            const guard = &work.guard.?;
            try requireGuardPolicy(self, a, work);
            if (guard.disposition == .diverged) return error.GuardDiverged;
            const bytes = try contracts.encodeOwned(data.invocation.Control, a, control);
            defer a.free(bytes);
            if (guard.pending_control) |owned| {
                if (!std.meta.eql(owned.digest, storage.digest(bytes)) or owned.bytes != bytes.len)
                    return error.GuardControlMismatch;
            } else guard.guest_quantum = quantum;
            _ = try workspaceConsumed(self, a, initial, control);
            if (guard.candidate_segment != null)
                return workspaceGuardReference(
                    self,
                    a,
                    parent,
                    work,
                    control,
                    bytes,
                    base_quantum,
                    operation_value,
                );
            return workspaceGuardCandidateAdvance(
                self,
                a,
                parent,
                work,
                control,
                bytes,
                base_quantum,
                operation_value,
            );
        }
        fn guardInitialMatches(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            segment: kosmos.RuntimeExperiment.Segment,
        ) !bool {
            const checkpoint = try store(self).object(a, work.checkpoint, null);
            defer a.free(checkpoint);
            return same(checkpoint, segment.checkpoint) and segment.guest_work == 0;
        }
        fn beginGuardCandidate(
            a: std.mem.Allocator,
            candidate: *kosmos.RuntimeExperiment.Experiment,
            control: data.invocation.Control,
            quantum: u64,
        ) !void {
            if (control == .reply) {
                var reply = try data.invocation.decode(data.invocation.Result, a, control.reply);
                defer reply.deinit();
                return candidate.begin(.{ .answer = reply.value.value }, quantum);
            }
            return candidate.begin(switch (control) {
                .none => .none,
                .resume_yield => .resume_yield,
                .cancel => |reason| .{ .cancel = reason },
                .reply => unreachable,
            }, quantum);
        }
        fn workspaceGuardFailure(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            work: workspace.Work,
            control: []const u8,
            failure: anyerror,
            operation_value: GuardOperation,
        ) !Admission {
            var next = work;
            next.guard.?.disposition = .incomplete;
            next.guard.?.failure = try name(@errorName(failure));
            return workspaceGuardRetain(self, a, parent, next, control, .{}, operation_value);
        }
        fn workspaceGuardDiverged(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            work: workspace.Work,
            control: []const u8,
            candidate: *kosmos.RuntimeExperiment.Experiment,
            operation_value: GuardOperation,
        ) !Admission {
            var next = work;
            next.guard.?.disposition = .diverged;
            const capsule = try candidate.checkpointOuter(a);
            defer a.free(capsule);
            return workspaceGuardRetain(
                self,
                a,
                parent,
                next,
                control,
                .{ .candidate = capsule },
                operation_value,
            );
        }
        fn workspaceGuardRetain(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: workspace.Work,
            control: []const u8,
            retained: GuardRetention,
            operation_value: GuardOperation,
        ) !Admission {
            var work = initial;
            const guard = &work.guard.?;
            guard.revision = try std.math.add(u64, guard.revision, 1);
            work.event_watermark = try std.math.add(u64, parent.event_high, 1);
            work.schedule = if (guard.disposition == .diverged or guard.failure != null or
                work.policy.continuation == .explicit_only) .parked else .queued;
            try store(self).begin();
            defer store(self).rollback();
            if (retained.candidate) |bytes| guard.continuation =
                try store(self).putObject(bytes);
            guard.pending_control = try store(self).putObject(control);
            if (retained.segment) |segment| guard.candidate_segment = .{
                .checkpoint = try store(self).putObject(segment.checkpoint),
                .observation = try store(self).putObject(segment.observation),
                .guest_work = segment.guest_work,
            };
            if (retained.code) |bytes| _ = try store(self).putObject(bytes);
            if (retained.reference) |bytes| guard.reference_operation = .{
                .capsule = try store(self).putObject(bytes),
                .dependencies = .{ .items = try capsuleDependencies(a, bytes) },
                .control = guard.pending_control.?,
                .guest_quantum = guard.guest_quantum,
            };
            defer if (retained.reference != null) a.free(
                guard.reference_operation.?.dependencies.items,
            );
            try store(self).putRecord(workspace.Work, "workspace_work", work.id, work.task, work);
            return workspaceCommit(
                self,
                a,
                parent,
                operation_value.operation_id,
                operation_value.request,
                work.id,
                .work,
                try snapshotRecord(self, workspace.Work, a, "workspace_work", work.id, work.task),
                operation_value.command,
            );
        }
        fn workspaceGuardReference(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: workspace.Work,
            control: data.invocation.Control,
            encoded: []const u8,
            base_quantum: u64,
            operation_value: GuardOperation,
        ) !Admission {
            var work = initial;
            const guard = &work.guard.?;
            var provisional = work;
            provisional.outer_operation = guard.reference_operation;
            const driver = try workspaceResident(self, a, provisional);
            errdefer retire(self, a) catch store(self).fence();
            const started = std.Io.Clock.awake.now(self.io);
            if (guard.reference_operation == null)
                try driver.beginAdvance(control, guard.guest_quantum);
            var progress = try driver.pump(base_quantum);
            defer progress.deinit();
            const elapsed = std.math.cast(u64, @max(
                0,
                std.Io.Clock.awake.now(self.io).nanoseconds - started.nanoseconds,
            )) orelse std.math.maxInt(u64);
            guard.reference_nanoseconds +|= elapsed;
            if (progress == .event and progress.event.value == .cut)
                return workspaceGuardCompare(
                    self,
                    a,
                    parent,
                    work,
                    control,
                    encoded,
                    driver,
                    elapsed,
                    operation_value,
                );
            if (progress != .suspended) return error.InvalidRuntimeProgress;
            const capsule = try driver.retainCapsule(runtimeProvenance(work));
            const code = try driver.runtimeBytes(a);
            defer a.free(code);
            const admitted = try workspaceGuardRetain(
                self,
                a,
                parent,
                work,
                encoded,
                .{ .reference = capsule, .code = code },
                operation_value,
            );
            self.active.?.outer_operation = .{
                .digest = storage.digest(capsule),
                .bytes = capsule.len,
            };
            return admitted;
        }
        fn workspaceGuardCompare(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            initial: workspace.Work,
            control: data.invocation.Control,
            encoded: []const u8,
            driver: *evaluator.Driver,
            elapsed: u64,
            operation_value: GuardOperation,
        ) !Admission {
            var work = initial;
            const guard = &work.guard.?;
            const started = std.Io.Clock.awake.now(self.io);
            var observed = try driver.runtimeObservation(a);
            defer observed.deinit();
            const segment = guard.candidate_segment.?;
            var publication = try driver.drive(a, .none, 0);
            publication.guest_work = observed.guest_work;
            defer a.free(publication.outcome);
            const preparation_elapsed = std.math.cast(u64, @max(
                0,
                std.Io.Clock.awake.now(self.io).nanoseconds - started.nanoseconds,
            )) orelse std.math.maxInt(u64);
            guard.reference_nanoseconds +|= preparation_elapsed;
            const agrees =
                std.meta.eql(storage.digest(publication.checkpoint), segment.checkpoint.digest) and
                publication.checkpoint.len == segment.checkpoint.bytes and
                std.meta.eql(storage.digest(observed.observation), segment.observation.digest) and
                observed.observation.len == segment.observation.bytes and
                observed.guest_work == segment.guest_work;
            if (!agrees) {
                try retire(self, a);
                guard.disposition = .diverged;
                return workspaceGuardRetain(self, a, parent, work, encoded, .{}, operation_value);
            }
            guard.pending_control = null;
            guard.reference_operation = null;
            guard.candidate_segment = null;
            guard.disposition = .agreed;
            guard.revision = try std.math.add(u64, guard.revision, 1);
            guard.agreed_segments = try std.math.add(u64, guard.agreed_segments, 1);
            errdefer store(self).fence();
            return workspaceFinish(
                self,
                a,
                parent,
                work,
                control,
                publication,
                elapsed +| preparation_elapsed,
                operation_value.operation_id,
                operation_value.request,
                operation_value.command,
            );
        }
    };
}
