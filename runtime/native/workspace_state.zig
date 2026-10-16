//! Workspace records are custody and observation, never an executable plan.
const contracts = @import("protean_contracts");
const state = @import("state.zig");
const std = @import("std");

pub fn custodyId(a: std.mem.Allocator, task: state.TaskId, content: state.Digest) !state.Digest {
    const Key = struct { task: state.TaskId, program: state.Digest };
    const bytes = try contracts.encodeOwned(Key, a, .{ .task = task, .program = content });
    defer a.free(bytes);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("agent.native.operation.v1\x00");
    hash.update(bytes);
    var result: state.Digest = undefined;
    hash.final(&result);
    return result;
}

pub const Subject = struct {
    task: state.TaskId,
    work: ?state.Digest = null,
};
/// Every occurrence has one immutable execution owner and exact image. This
/// remains valid when the parent journal or the physical resident changes.
pub const ExecutionRoute = struct {
    id: state.Digest,
    task: state.TaskId,
    work: ?state.Digest,
    image: state.Reference,
    program_identity: state.Digest,
    port: ?state.Reference = null,
    delegation: ?state.Reference = null,
};
pub const Wait = struct {
    id: state.Digest,
    task: state.TaskId,
    request: state.Reference,
    selection: @FieldType(contracts.workspace.Work, "wait"),
};

pub const Operation = enum { build, start, control, interact, specialize, realize, request_cut, pump };
pub const Command = union(enum) { advance, park, delegate: RunPolicy, cancel: state.Reason };

pub const RunPolicy = contracts.workspace.Policy;

/// Content identity excludes task custody. Interfaces are canonical Horos
/// descriptors derived from the admitted image, not model-supplied assertions.
pub const ProgramArtifact = struct {
    version: u32 = 1,
    source: state.Reference,
    source_kind: enum { source_records, component_recipe, instrument_model, instrument_snapshot },
    construction_contract: state.Name,
    authoring_identity: state.Digest,
    image: state.Reference,
    input_schema: state.Reference,
    result_schema: state.Reference,
    failure_schema: state.Reference,
    catalog: ?state.Reference = null,
    exposures: contracts.Vector(contracts.workspace.Exposure, null) = .{ .items = &.{} },
    ports: contracts.Vector(PortInterface, null) = .{ .items = &.{} },
};

pub const PortInterface = struct {
    identity: contracts.Utf8,
    class: @FieldType(contracts.workspace.Exposure, "class"),
    argument: state.Reference,
    observation: state.Reference,
    payload: state.Reference,
    command: state.Reference,
};

/// Immutable binding to one real pending driver request. The continuation
/// itself remains exclusively in the work checkpoint.
pub const Port = struct {
    id: state.Digest,
    task: state.TaskId,
    work: state.Digest,
    program: state.Reference,
    occurrence: state.Digest,
    request: state.Reference,
    request_identity: state.Digest,
    generation: u64,
    interface: PortInterface,
    payload: state.Reference,
};
pub const PortReply = struct {
    id: state.Digest,
    task: state.TaskId,
    port: state.Reference,
    reply: state.Reference,
    input: ?state.Reference,
    command: enum { resume_value, finish },
};

/// Task-scoped access to immutable, reusable program content.
pub const Program = struct {
    id: state.Digest,
    task: state.TaskId,
    artifact: state.Reference,
    description: ProgramArtifact,
};

/// Approved by this host's exact source/translation checker, scoped to the
/// existing task and guest program. Content possession alone is insufficient.
pub const Runtime = struct {
    id: state.Digest,
    task: state.TaskId,
    program: state.Digest,
    artifact: state.Reference,
};

/// One source-derived cut observation and the exact machine that produced it.
pub const RuntimeTrace = struct {
    output: @import("kosmos").RuntimeInstrumentation.Output,
    capsule: state.Reference,
    dependencies: contracts.Vector(state.Reference, null),
};

pub const OuterOperation = state.OuterOperation;

pub const Work = struct {
    version: u32 = 2,
    id: state.Digest,
    task: state.TaskId,
    origin_work: ?state.Digest = null,
    delegation: ?state.Reference = null,
    answer_value: ?state.Reference = null,
    instrument_occurrence: ?state.Digest = null,
    program: state.Digest,
    runtime: ?state.Reference = null,
    realization_revision: u64 = 0,
    /// Read-only published capsule; execution still belongs to the work owner.
    runtime_capsule: ?state.Reference = null,
    runtime_trace: ?RuntimeTrace = null,
    outer_operation: ?OuterOperation = null,
    runtime_dependencies: contracts.Vector(state.Reference, null) = .{ .items = &.{} },
    input: state.Reference,
    input_value: ?state.Reference = null,
    checkpoint: state.Reference,
    outcome: state.Reference,
    outcome_kind: state.Outcome,
    execution_revision: u64,
    control_revision: u64,
    schedule: state.Schedule,
    blocker: ?state.Blocker = null,
    policy: RunPolicy,
    current_occurrence: ?state.Digest = null,
    current_port: ?state.Reference = null,
    port_generation: u64 = 0,
    result: ?state.Reference = null,
    result_value: ?state.Reference = null,
    cancellation: ?state.Reason = null,
    cancellation_applied: bool = false,
    event_watermark: u64,
    /// All antecedents remain explicit even when equal results are deduplicated.
    inputs: contracts.Vector(state.Reference, null) = .{ .items = &.{} },
    /// Measured owner drive/publication time, excluding I/O wait and inference.
    /// Informational accounting, never execution or import authority.
    native_publication_nanoseconds: u64 = 0,

    pub fn terminal(self: Work) bool {
        return switch (self.outcome_kind) {
            .completed, .failed, .cancelled => true,
            else => false,
        };
    }
};

/// A receipt observes one committed instant. The live occurrence can later
/// change without changing this work revision or its replayed observation.
pub const WorkObservation = struct {
    work: Work,
    occurrence: ?@import("occurrence.zig").Occurrence,
};

/// Native control facts are checked independently of the execution checkpoint.
/// Keep only the facts needed to validate adjacent journal publications.
pub const ControlObservation = struct {
    policy: RunPolicy,
    schedule: state.Schedule,
    blocker: ?state.Blocker,
    cancellation: ?state.Reason,
    cancellation_applied: bool,
    outcome: state.Outcome,
    instrument: bool,
    port: bool,
    delivery: ?std.meta.Tag(@import("occurrence.zig").State),

    pub fn from(observed: WorkObservation) ControlObservation {
        const work = observed.work;
        return .{ .policy = work.policy, .schedule = work.schedule, .blocker = work.blocker, .cancellation = work.cancellation, .cancellation_applied = work.cancellation_applied, .outcome = work.outcome_kind, .instrument = work.delegation != null, .port = work.current_port != null, .delivery = if (observed.occurrence) |pending| std.meta.activeTag(pending.state) else null };
    }
};

pub const StartRequest = struct { method: state.Method = .workspace, kind: Operation = .start, task: state.TaskId, program: state.Digest, input: contracts.Bytes(null), policy: RunPolicy, origin: ?state.Reference, runtime: ?state.Reference = null };
pub const SpecializeRequest = struct { method: state.Method = .workspace, kind: Operation = .specialize, task: state.TaskId, program: state.Digest, hooks: contracts.workspace.RuntimeHooks = .{} };
pub const RealizeRequest = struct { method: state.Method = .workspace, kind: Operation = .realize, task: state.TaskId, work: state.Digest, execution: u64, control: u64, realization: u64, runtime: ?state.Reference };
pub const CutRequest = struct { method: state.Method = .workspace, kind: Operation = .request_cut, task: state.TaskId, command: @FieldType(contracts.workspace.Work, "request_cut") };
pub const PumpRequest = struct { method: state.Method = .workspace, kind: Operation = .pump, task: state.TaskId, command: @FieldType(contracts.workspace.Work, "pump") };
pub const ControlRequest = struct { method: state.Method = .workspace, kind: Operation = .control, task: state.TaskId, work: state.Digest, execution: u64, control: u64, command: Command };
pub const InteractionRequest = struct { kind: Operation = .interact, task: state.TaskId, interaction: @FieldType(contracts.workspace.Work, "interact") };
pub const DelegationRequest = struct { task: state.TaskId, command: @FieldType(contracts.workspace.Work, "delegate") };
pub const BuildRequest = struct { method: state.Method = .workspace, kind: Operation = .build, task: state.TaskId, source: contracts.Bytes(null), source_kind: contracts.workspace.SourceKind, catalog: ?state.Reference, exposures: contracts.Vector(contracts.workspace.Exposure, null) };
pub const ContextRequest = struct { task: state.TaskId, command: contracts.workspace.Context, snapshot: ?state.Reference, input: ?state.Reference };

/// The existing receipt binds these inputs by request digest. Start input bytes
/// and identity already have immutable work custody, so do not copy them here.
pub const PublicationCommand = union(enum) {
    build,
    specialize: struct { program: state.Digest, hooks: contracts.workspace.RuntimeHooks = .{} },
    realize: struct { execution: u64, control: u64, realization: u64, runtime: ?state.Reference, source: state.Reference, target: state.Reference, dependencies: contracts.Vector(state.Reference, null) },
    request_cut: @FieldType(contracts.workspace.Work, "request_cut"),
    pump: @FieldType(contracts.workspace.Work, "pump"),
    context: struct { command: contracts.workspace.Context, snapshot: ?state.Reference, input: ?state.Reference },
    start: struct { policy: RunPolicy, origin: bool, runtime: ?state.Reference = null },
    control: struct { execution: u64, control: u64, command: Command },
    interact: @FieldType(contracts.workspace.Work, "interact"),
    delegate: @FieldType(contracts.workspace.Work, "delegate"),
};

/// Inputs to a read projection, captured before later work can replace them.
/// Executable claims in each work are checked against its retained checkpoint.
pub const ReadObservation = union(enum) {
    immutable,
    works: struct {
        works: contracts.Vector(?WorkObservation, null),
        event_watermark: u64,
    },
    /// The retained event prefix determines which work had been published.
    scope: u64,
    wait: struct {
        works: contracts.Vector(?WorkObservation, null),
        interrupted: bool,
        event_watermark: u64,
    },
};

/// The local operation owns these inputs; reply JSON is always a projection.
/// Rejections retain a native diagnostic event, never a result or authority.
pub const ReplyEvidence = union(enum) {
    read: ReadObservation,
    admitted: struct { replayed: bool },
    placement: state.Reference,
    rejected: struct {
        stage: enum { authorization, preparation, operation },
        code: state.Name,
    },
};
pub const ReplyObservation = struct {
    id: state.Digest,
    task: state.TaskId,
    attempt: state.Digest,
    request: state.Reference,
    evidence: ReplyEvidence,
};

/// Epistemic origin is retained alongside canonical values. Equal payloads do
/// not erase independent origins or convert a hypothesis into an acquisition.
pub const Derivation = struct {
    kind: enum { hypothesis, computation, acquisition, judgment, inspection },
    sources: contracts.Vector(state.Reference, null),
    program: ?state.Reference = null,
    work: ?state.Digest = null,
    acquisition: ?SnapshotRange = null,
    frozen_input: ?state.Reference = null,
    delegation: ?state.Reference = null,
    capture: ?state.Reference = null,
    inspection: ?Inspection = null,
};

/// Ordinary immutable evidence. Nominal references in the retained snapshot
/// keep its checkpoint and runtime dependencies inside archive closure.
pub const Inspection = struct {
    observation: WorkObservation,
    nodes: contracts.workspace.NodeScope,
    runtime_code: state.Reference,
};

pub const ModelBinding = struct {
    profile_id: contracts.Text(64),
    profile_digest: state.Digest,
    settings: @import("responses.zig").Settings,
    reasoning_mode: contracts.Text(32),
    reasoning_context: contracts.Text(32),
};
/// Admission belongs to one actual controller action and one actual port. The
/// instrument has its own ordinary image, checkpoint, occurrence and attempt.
pub const Delegation = struct {
    id: state.Digest,
    task: state.TaskId,
    parent_occurrence: state.Digest,
    parent_request: state.Reference,
    work: state.Digest,
    instrument: state.Digest,
    program: state.Reference,
    port: state.Reference,
    control_revision: u64,
    selection: contracts.workspace.Interpretation,
    model: ?ModelBinding = null,
    snapshot: ?state.Reference = null,
    inputs: contracts.Vector(state.Reference, null),
};
pub const SnapshotRange = struct {
    snapshot: state.Reference,
    path: contracts.Utf8,
    file_digest: state.Digest,
    start: u64,
    end: u64,
    file_bytes: u64,
    excluded_entries: u64,
};
/// The compiled adapter supplies its exact frozen read binding only after
/// admitting the original model action and its current permission.
pub const Authorized = struct {
    command: contracts.workspace.Command,
    snapshot: ?state.Reference = null,
    catalog: ?state.Reference = null,
    input: ?state.Reference = null,
    model: ?ModelBinding = null,
};
pub const ValueArtifact = struct {
    version: u32 = 1,
    schema: state.Reference,
    value: state.Reference,
    provenance: state.Reference,
};
pub const Value = struct {
    id: state.Digest,
    task: state.TaskId,
    artifact: state.Reference,
    description: ValueArtifact,
    derivation: Derivation,
};

/// The selected set is complete; it makes no claim about the universe from
/// which the controller chose it. Each value retains its own derivation.
pub const ViewArtifact = struct {
    version: u32 = 1,
    values: contracts.Vector(state.Reference, null),
    coverage: enum { selected_values_only } = .selected_values_only,
};
pub const View = struct {
    id: state.Digest,
    task: state.TaskId,
    artifact: state.Reference,
    description: ViewArtifact,
};
