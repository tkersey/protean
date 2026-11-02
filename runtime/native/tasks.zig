//! Sole native task/occurrence mutation owner. Front ends submit ordinary typed
//! inputs; workers return acquired bytes. Neither can drive a Kosmos resident.
const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("state.zig");
const occurrence = @import("occurrence.zig");
const Namespace = @import("namespace.zig").Namespace;
const evaluator = @import("driver.zig");
const kosmos = @import("kosmos");
const registry = @import("registry.zig");
const discovery = @import("discovery.zig");
const json = @import("json.zig");
const values = @import("values.zig");
const workspace = @import("workspace_state.zig");
const wc = contracts.workspace;
const construction = @import("program_construction.zig");
const archive_api = @import("archive.zig");

const task_types = @import("tasks/types.zig");

pub const cleanupComplete = task_types.cleanupComplete;
pub const Profile = task_types.Profile;
pub const SemanticPolicy = task_types.SemanticPolicy;
pub const FrozenInputs = task_types.FrozenInputs;
pub const Admission = task_types.Admission;
pub const RecoveryAvailability = task_types.RecoveryAvailability;
pub const Status = task_types.Status;
pub const Work = task_types.Work;
pub const WorkResult = task_types.WorkResult;
pub const Step = task_types.Step;

const Active = task_types.Active;
const CompilerFact = task_types.CompilerFact;
const PlacementJob = task_types.PlacementJob;
const PlacementPending = task_types.PlacementPending;
const RuntimeCache = task_types.RuntimeCache;

pub fn Service(comptime Types: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        io: std.Io,
        namespace: *Namespace,
        assets: discovery.Assets,
        application: *const discovery.Application,
        handlers: registry.Registry,
        profile: Profile,
        program: *evaluator.Program,
        active: ?Active = null,
        /// Only this process's explicit admissions/resumes are runnable. Merely
        /// opening a namespace never resumes a persisted task.
        runnable: std.ArrayList(workspace.Subject) = .empty,
        /// Logical queue order is items[cursor..] followed by items[0..cursor].
        /// Advancing a turn must not move every remaining ID.
        runnable_cursor: usize = 0,
        /// Unsettled cleanup retains ownership, but never runnable work.
        owned: std.ArrayList(state.TaskId) = .empty,
        cleanup_cursor: usize = 0,
        shutdown_cancel_requested: bool = false,
        remote_stopped_parent: ?state.TaskId = null,
        owner_epoch: state.Digest = undefined,
        work: ?Work = null,
        placement_pending: std.ArrayList(PlacementPending) = .empty,
        placement_job: ?PlacementJob = null,
        checked_workspace_programs: std.AutoHashMapUnmanaged(state.Digest, u64) = .empty,
        checked_workspace_runtimes: std.AutoHashMapUnmanaged(CompilerFact, u64) = .empty,
        runtime_cache: ?RuntimeCache = null,
        compiler_facts: ?*CompilerFacts = null,
        reuse_provenance_validation: bool = false,
        // Import may use ordinary mutation projections only through an existing
        // matching receipt. Missing receipts must never execute a new mutation.
        workspace_replay: ?struct {
            replayed: bool,
            records: []const state.ArchiveRecord,
            checked: *SnapshotValidation,
        } = null,
        pub const CompilerFacts = @import("tasks/compiler_preparation.zig").Operations(
            Types,
            Self,
        ).CompilerFacts;
        const SnapshotValidation = @import("tasks/workspace_snapshots.zig").Operations(
            Types,
            Self,
        ).SnapshotValidation;
        pub fn init(
            a: std.mem.Allocator,
            io: std.Io,
            namespace: *Namespace,
            assets: discovery.Assets,
            application: *const discovery.Application,
            handlers: registry.Registry,
            profile: Profile,
        ) !Self {
            const domain = @import("tasks/lifecycle.zig").Operations(Types, Self);
            return domain.init(a, io, namespace, assets, application, handlers, profile);
        }
        pub fn task(
            self: *Self,
            a: std.mem.Allocator,
            id: state.TaskId,
        ) !contracts.Decoded(state.Task) {
            const domain = @import("tasks/task_queries.zig").Operations(Types, Self);
            return domain.task(self, a, id);
        }
        pub fn schemaArtifact(self: *Self, id: state.Digest) !discovery.Artifact {
            const domain = @import("tasks/task_queries.zig").Operations(Types, Self);
            return domain.schemaArtifact(self, id);
        }
        pub fn projectedArtifact(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
        ) !state.Reference {
            const domain = @import("tasks/task_queries.zig").Operations(Types, Self);
            return domain.projectedArtifact(self, a, task_id, id);
        }
        pub fn frozenInputs(self: *Self, a: std.mem.Allocator, id: state.TaskId) !FrozenInputs {
            const domain = @import("tasks/task_queries.zig").Operations(Types, Self);
            return domain.frozenInputs(self, a, id);
        }
        pub fn frozenArchiveInputs(
            self: *Self,
            a: std.mem.Allocator,
            path: []const u8,
        ) !FrozenInputs {
            const domain = @import("tasks/task_queries.zig").Operations(Types, Self);
            return domain.frozenArchiveInputs(self, a, path);
        }
        pub fn pendingQuestion(
            self: *Self,
            a: std.mem.Allocator,
            id: state.TaskId,
        ) !?contracts.Decoded(state.Question) {
            const domain = @import("tasks/task_queries.zig").Operations(Types, Self);
            return domain.pendingQuestion(self, a, id);
        }
        pub fn status(self: *Self, a: std.mem.Allocator, value: state.Task) !Status {
            const domain = @import("tasks/task_queries.zig").Operations(Types, Self);
            return domain.status(self, a, value);
        }
        pub fn taskCleanupComplete(self: *Self, a: std.mem.Allocator, value: state.Task) !bool {
            const domain = @import("tasks/task_queries.zig").Operations(Types, Self);
            return domain.taskCleanupComplete(self, a, value);
        }
        pub fn associatedWorkDisposed(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
        ) !bool {
            const domain = @import("tasks/task_queries.zig").Operations(Types, Self);
            return domain.associatedWorkDisposed(self, a, task_id);
        }
        pub fn shutdownIncomplete(self: *Self, a: std.mem.Allocator) !bool {
            const domain = @import("tasks/task_queries.zig").Operations(Types, Self);
            return domain.shutdownIncomplete(self, a);
        }
        pub fn cancelOwned(
            self: *Self,
            a: std.mem.Allocator,
            instance: []const u8,
            reason: []const u8,
        ) !void {
            const domain = @import("tasks/task_queries.zig").Operations(Types, Self);
            return domain.cancelOwned(self, a, instance, reason);
        }
        pub fn placementActive(self: *const Self) bool {
            const domain = @import("tasks/task_queries.zig").Operations(Types, Self);
            return domain.placementActive(self);
        }
        pub fn submit(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            input: Types.Input,
        ) !Admission {
            const domain = @import("tasks/admission.zig").Operations(Types, Self);
            return domain.submit(self, a, id, input);
        }
        pub fn requestCancel(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            task_id: state.TaskId,
            reason: []const u8,
        ) !Admission {
            const domain = @import("tasks/cancellation.zig").Operations(Types, Self);
            return domain.requestCancel(self, a, id, task_id, reason);
        }
        pub fn resumeTask(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            task_id: state.TaskId,
            expected: u64,
        ) !Admission {
            const domain = @import("tasks/cancellation.zig").Operations(Types, Self);
            return domain.resumeTask(self, a, id, task_id, expected);
        }
        pub fn recoveryAvailability(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
        ) !?RecoveryAvailability {
            const domain = @import("tasks/reconciliation.zig").Operations(Types, Self);
            return domain.recoveryAvailability(self, a, task_id);
        }
        pub fn subjectRecoveryAvailability(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            residual_id: ?state.Digest,
        ) !?RecoveryAvailability {
            const domain = @import("tasks/reconciliation.zig").Operations(Types, Self);
            return domain.subjectRecoveryAvailability(self, a, task_id, residual_id);
        }
        pub fn reconciliation(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
        ) !contracts.Decoded(state.Reconciliation) {
            const domain = @import("tasks/reconciliation.zig").Operations(Types, Self);
            return domain.reconciliation(self, a, task_id, id);
        }
        pub fn reconcile(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            task_id: state.TaskId,
            expected: u64,
            occurrence_id: state.Digest,
            attempt_id: state.Digest,
            recovery: state.RecoveryRequest,
        ) !Admission {
            const domain = @import("tasks/reconciliation.zig").Operations(Types, Self);
            return domain.reconcile(
                self,
                a,
                id,
                task_id,
                expected,
                occurrence_id,
                attempt_id,
                recovery,
            );
        }
        pub fn message(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            task_id: state.TaskId,
            input: Types.Message,
        ) !Admission {
            const domain = @import("tasks/messages.zig").Operations(Types, Self);
            return domain.message(self, a, id, task_id, input);
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
            const domain = @import("tasks/messages.zig").Operations(Types, Self);
            return domain.respond(
                self,
                a,
                id,
                task_id,
                question_id,
                revision,
                request_digest,
                schema_id,
                answer_json,
            );
        }
        pub fn pump(self: *Self, a: std.mem.Allocator) !Step {
            const domain = @import("tasks/scheduling.zig").Operations(Types, Self);
            return domain.pump(self, a);
        }
        pub fn adoptController(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            expected_revision: u64,
            command: wc.Adoption,
        ) !Admission {
            const domain = @import("tasks/controller_succession.zig").Operations(Types, Self);
            return domain.adoptController(
                self,
                a,
                operation_id,
                task_id,
                expected_revision,
                command,
            );
        }
        pub fn shouldCancelWork(self: *Self, work: Work) !bool {
            const domain = @import("tasks/worker_execution.zig").Operations(Types, Self);
            return domain.shouldCancelWork(self, work);
        }
        pub fn completeWork(
            self: *Self,
            a: std.mem.Allocator,
            work: Work,
            result: WorkResult,
        ) !void {
            const domain = @import("tasks/worker_execution.zig").Operations(Types, Self);
            return domain.completeWork(self, a, work, result);
        }
        pub fn acquire(self: *Self, a: std.mem.Allocator, work: Work, reply: []const u8) !void {
            const domain = @import("tasks/worker_execution.zig").Operations(Types, Self);
            return domain.acquire(self, a, work, reply);
        }
        pub fn unknown(self: *Self, a: std.mem.Allocator, work: Work) !void {
            const domain = @import("tasks/worker_execution.zig").Operations(Types, Self);
            return domain.unknown(self, a, work);
        }
        pub fn notSent(self: *Self, a: std.mem.Allocator, work: Work) !void {
            const domain = @import("tasks/worker_execution.zig").Operations(Types, Self);
            return domain.notSent(self, a, work);
        }
        pub fn recoverPlacementFiles(self: *Self, a: std.mem.Allocator) !void {
            const domain = @import("tasks/placement_transport.zig").Operations(Types, Self);
            return domain.recoverPlacementFiles(self, a);
        }
        pub fn placementRequest(
            self: *Self,
            a: std.mem.Allocator,
            request: @import("placement.zig").Request,
        ) !json.Value {
            const domain = @import("tasks/placement_transport.zig").Operations(Types, Self);
            return domain.placementRequest(self, a, request);
        }
        pub fn placementStatus(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("placement.zig").Subject,
        ) !?@import("placement.zig").Custody {
            const domain = @import("tasks/placement_control.zig").Operations(Types, Self);
            return domain.placementStatus(self, a, subject);
        }
        pub fn placementControl(
            self: *Self,
            a: std.mem.Allocator,
            operation_name: []const u8,
            task_id: state.TaskId,
            command: wc.Work,
        ) ![]u8 {
            const domain = @import("tasks/placement_control.zig").Operations(Types, Self);
            return domain.placementControl(self, a, operation_name, task_id, command);
        }
        pub fn placementExecuteControl(
            self: *Self,
            a: std.mem.Allocator,
            peer_name: []const u8,
            signed: @import("placement.zig").Signed(@import("placement.zig").Control),
        ) ![]u8 {
            const domain = @import("tasks/placement_control.zig").Operations(Types, Self);
            return domain.placementExecuteControl(self, a, peer_name, signed);
        }
        pub fn placementResolveControl(
            self: *Self,
            a: std.mem.Allocator,
            peer_name: []const u8,
            signed: @import("placement.zig").Signed(@import("placement.zig").Control),
            route: []const @import("placement.zig").Succession,
        ) ![]u8 {
            const domain = @import("tasks/placement_control.zig").Operations(Types, Self);
            return domain.placementResolveControl(self, a, peer_name, signed, route);
        }
        pub fn placementFollowExecutor(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            control_id: state.Digest,
            next: @import("placement.zig").Succession,
        ) !void {
            const domain = @import("tasks/placement_control.zig").Operations(Types, Self);
            return domain.placementFollowExecutor(self, a, task_id, control_id, next);
        }
        pub fn placementApplyReport(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            control_id: state.Digest,
            report: @import("placement.zig").Signed(@import("placement.zig").Report),
        ) !void {
            const domain = @import("tasks/placement_control.zig").Operations(Types, Self);
            return domain.placementApplyReport(self, a, task_id, control_id, report);
        }
        pub fn placementFollowBehavior(
            self: *Self,
            a: std.mem.Allocator,
            decision: @import("placement.zig").Signed(@import("placement.zig").Behavior),
        ) !void {
            const domain = @import("tasks/placement_control.zig").Operations(Types, Self);
            return domain.placementFollowBehavior(self, a, decision);
        }
        pub fn placementFollowController(
            self: *Self,
            a: std.mem.Allocator,
            source_peer: []const u8,
            destination_peer: []const u8,
            offer: @import("placement.zig").Signed(@import("placement.zig").Offer),
            decision: @import("placement.zig").Signed(@import("placement.zig").Decision),
        ) !void {
            const domain = @import("tasks/placement_control.zig").Operations(Types, Self);
            return domain.placementFollowController(
                self,
                a,
                source_peer,
                destination_peer,
                offer,
                decision,
            );
        }
        pub fn placementAbortUnsent(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("placement.zig").Subject,
            transfer: state.Digest,
        ) !void {
            const domain = @import("tasks/placement_control.zig").Operations(Types, Self);
            return domain.placementAbortUnsent(self, a, subject, transfer);
        }
        pub fn placementWithdraw(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            transfer: state.Digest,
        ) !void {
            const domain = @import("tasks/placement_control.zig").Operations(Types, Self);
            return domain.placementWithdraw(self, a, task_id, transfer);
        }
        pub fn placementCompatibility(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("placement.zig").Subject,
        ) !@import("placement.zig").Compatibility {
            const domain = @import("tasks/placement_custody.zig").Operations(Types, Self);
            return domain.placementCompatibility(self, a, subject);
        }
        pub fn placementCut(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("placement.zig").Subject,
        ) !@import("placement.zig").Cut {
            const domain = @import("tasks/placement_custody.zig").Operations(Types, Self);
            return domain.placementCut(self, a, subject);
        }
        pub fn placementFreeze(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("placement.zig").Subject,
            peer_name: []const u8,
            expected: @import("placement.zig").Cut,
            transfer: state.Digest,
        ) !@import("placement.zig").Intent {
            const domain = @import("tasks/placement_custody.zig").Operations(Types, Self);
            return domain.placementFreeze(self, a, subject, peer_name, expected, transfer);
        }
        pub fn placementOffer(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("placement.zig").Subject,
            peer_name: []const u8,
            path: []const u8,
        ) !@import("placement.zig").Signed(@import("placement.zig").Offer) {
            const domain = @import("tasks/placement_custody.zig").Operations(Types, Self);
            return domain.placementOffer(self, a, subject, peer_name, path);
        }
        pub fn placementMove(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("placement.zig").Subject,
            peer_name: []const u8,
            expected: @import("placement.zig").Cut,
            transfer: state.Digest,
        ) !@import("placement.zig").Signed(@import("placement.zig").Decision) {
            const domain = @import("tasks/placement_custody.zig").Operations(Types, Self);
            return domain.placementMove(self, a, subject, peer_name, expected, transfer);
        }
        pub fn placementApplyDecision(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("placement.zig").Subject,
            signed: @import("placement.zig").Signed(@import("placement.zig").Decision),
        ) !void {
            const domain = @import("tasks/placement_custody.zig").Operations(Types, Self);
            return domain.placementApplyDecision(self, a, subject, signed);
        }
        pub fn placementRefuse(
            self: *Self,
            a: std.mem.Allocator,
            peer_name: []const u8,
            offered: @import("placement.zig").Signed(@import("placement.zig").Offer),
            reason: @import("placement.zig").Refusal,
        ) !@import("placement.zig").Signed(@import("placement.zig").Decision) {
            const domain = @import("tasks/placement_custody.zig").Operations(Types, Self);
            return domain.placementRefuse(self, a, peer_name, offered, reason);
        }
        pub fn exportCheckpoint(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            path: []const u8,
        ) !archive_api.Exported {
            const domain = @import("tasks/checkpoint.zig").Operations(Types, Self);
            return domain.exportCheckpoint(self, a, task_id, path);
        }
        pub fn importCheckpoint(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            path: []const u8,
        ) !Admission {
            const domain = @import("tasks/checkpoint.zig").Operations(Types, Self);
            return domain.importCheckpoint(self, a, id, path);
        }
        pub fn placementAccept(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            peer_name: []const u8,
            offered: @import("placement.zig").Signed(@import("placement.zig").Offer),
            path: []const u8,
        ) !@import("placement.zig").Signed(@import("placement.zig").Decision) {
            const domain = @import("tasks/checkpoint.zig").Operations(Types, Self);
            return domain.placementAccept(self, a, operation_id, peer_name, offered, path);
        }
        pub fn workspaceCommand(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            command: wc.Command,
        ) !wc.Reply {
            const domain = @import("tasks/workspace_commands.zig").Operations(Types, Self);
            return domain.workspaceCommand(self, a, operation_id, task_id, command);
        }
        pub fn workspaceCandidate(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            digest: state.Digest,
        ) !contracts.Decoded(workspace.Candidate) {
            const domain = @import("tasks/workspace_observations.zig").Operations(Types, Self);
            return domain.workspaceCandidate(self, a, task_id, digest);
        }
        pub fn workspaceInteract(
            self: *Self,
            allocator: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            interaction: @FieldType(wc.Work, "interact"),
        ) !Admission {
            const domain = @import("tasks/workspace_interaction.zig").Operations(Types, Self);
            return domain.workspaceInteract(self, allocator, operation_id, task_id, interaction);
        }
        pub fn workspaceSpecialize(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            program_id: state.Digest,
        ) !Admission {
            const domain = @import("tasks/workspace_programs.zig").Operations(Types, Self);
            return domain.workspaceSpecialize(self, a, operation_id, task_id, program_id);
        }
        pub fn workspaceSpecializeWithHooks(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            program_id: state.Digest,
            hooks: wc.RuntimeHooks,
        ) !Admission {
            const domain = @import("tasks/workspace_programs.zig").Operations(Types, Self);
            return domain.workspaceSpecializeWithHooks(
                self,
                a,
                operation_id,
                task_id,
                program_id,
                hooks,
            );
        }
        pub fn workspaceGuard(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            command: @FieldType(workspace.GuardRequest, "command"),
        ) !Admission {
            const domain = @import("tasks/workspace_guards.zig").Operations(Types, Self);
            return domain.workspaceGuard(self, a, operation_id, task_id, command);
        }
        pub fn workspaceRequestCut(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            command: @FieldType(wc.Work, "request_cut"),
        ) !Admission {
            const domain = @import("tasks/workspace_realization.zig").Operations(Types, Self);
            return domain.workspaceRequestCut(self, a, operation_id, task_id, command);
        }
        pub fn workspaceRealizeController(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            command: @FieldType(wc.Work, "realize_controller"),
        ) !Admission {
            const domain = @import("tasks/workspace_realization.zig").Operations(Types, Self);
            return domain.workspaceRealizeController(self, a, operation_id, task_id, command);
        }
        pub fn workspaceRealize(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            command: @FieldType(wc.Work, "realize"),
        ) !Admission {
            const domain = @import("tasks/workspace_realization.zig").Operations(Types, Self);
            return domain.workspaceRealize(self, a, operation_id, task_id, command);
        }
        pub fn workspaceProgram(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            program_id: state.Digest,
        ) !contracts.Decoded(workspace.Program) {
            const domain = @import("tasks/workspace_programs.zig").Operations(Types, Self);
            return domain.workspaceProgram(self, a, task_id, program_id);
        }
        pub fn workspaceWork(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            work_id: state.Digest,
        ) !contracts.Decoded(workspace.Work) {
            const domain = @import("tasks/workspace_programs.zig").Operations(Types, Self);
            return domain.workspaceWork(self, a, task_id, work_id);
        }
        pub fn validateWorkspace(
            self: *Self,
            allocator: std.mem.Allocator,
            task_id: state.TaskId,
        ) !void {
            const domain = @import("tasks/workspace_snapshots.zig").Operations(Types, Self);
            return domain.validateWorkspace(self, allocator, task_id);
        }
        pub fn prepareWorkspaceValidation(self: *Self, task_id: state.TaskId) !CompilerFacts {
            const domain = @import("tasks/workspace_snapshots.zig").Operations(Types, Self);
            return domain.prepareWorkspaceValidation(self, task_id);
        }
        pub fn validateWorkspaceRecordsPrepared(
            self: *Self,
            allocator: std.mem.Allocator,
            task_id: state.TaskId,
            records: []const state.ArchiveRecord,
            facts: *CompilerFacts,
        ) !void {
            const domain = @import("tasks/workspace_snapshots.zig").Operations(Types, Self);
            return domain.validateWorkspaceRecordsPrepared(
                self,
                allocator,
                task_id,
                records,
                facts,
            );
        }
        pub fn validateWorkspaceRecords(
            self: *Self,
            allocator: std.mem.Allocator,
            task_id: state.TaskId,
            records: []const state.ArchiveRecord,
        ) !void {
            const domain = @import("tasks/workspace_snapshots.zig").Operations(Types, Self);
            return domain.validateWorkspaceRecords(self, allocator, task_id, records);
        }
        pub fn workspaceBuild(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            source: []const u8,
            diagnostic: *construction.Diagnostic,
        ) !Admission {
            const domain = @import("tasks/workspace_programs.zig").Operations(Types, Self);
            return domain.workspaceBuild(self, a, operation_id, task_id, source, diagnostic);
        }
        pub fn controllerContract(
            self: *Self,
            a: std.mem.Allocator,
        ) !contracts.controller.Contract {
            const domain = @import("tasks/workspace_programs.zig").Operations(Types, Self);
            return domain.controllerContract(self, a);
        }
        pub fn workspaceStopObserving(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            task_id: state.TaskId,
            expected: wc.Expected,
        ) !Admission {
            const domain = @import("tasks/workspace_observers.zig").Operations(Types, Self);
            return domain.workspaceStopObserving(self, a, id, task_id, expected);
        }
        pub fn workspaceObserve(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            selection: wc.Observe,
        ) !Admission {
            const domain = @import("tasks/workspace_observers.zig").Operations(Types, Self);
            return domain.workspaceObserve(self, a, operation_id, task_id, selection);
        }
        pub fn workspaceStart(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            program_id: state.Digest,
            input: []const u8,
            policy: workspace.RunPolicy,
        ) !Admission {
            const domain = @import("tasks/workspace_start.zig").Operations(Types, Self);
            return domain.workspaceStart(self, a, operation_id, task_id, program_id, input, policy);
        }
        pub fn discardTask(self: *Self, a: std.mem.Allocator, task_id: state.TaskId) !void {
            const domain = @import("tasks/disposal.zig").Operations(Types, Self);
            return domain.discardTask(self, a, task_id);
        }
        pub fn workspacePump(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            command: @FieldType(wc.Work, "pump"),
        ) !Admission {
            const domain = @import("tasks/workspace_execution.zig").Operations(Types, Self);
            return domain.workspacePump(self, a, operation_id, task_id, command);
        }
        pub fn workspaceControl(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            work_id: state.Digest,
            expected_execution: u64,
            expected_control: u64,
            command: workspace.Command,
        ) !Admission {
            const domain = @import("tasks/workspace_control.zig").Operations(Types, Self);
            return domain.workspaceControl(
                self,
                a,
                operation_id,
                task_id,
                work_id,
                expected_execution,
                expected_control,
                command,
            );
        }
        pub fn close(self: *Self, a: std.mem.Allocator) !void {
            const domain = @import("tasks/lifecycle.zig").Operations(Types, Self);
            return domain.close(self, a);
        }
        pub fn park(self: *Self, a: std.mem.Allocator) !void {
            const domain = @import("tasks/lifecycle.zig").Operations(Types, Self);
            return domain.park(self, a);
        }
    };
}
