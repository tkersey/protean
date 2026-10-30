const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const evaluator = @import("../driver.zig");
const kosmos = @import("kosmos");
const registry = @import("../registry.zig");
const json = @import("../json.zig");
const workspace = @import("../workspace_state.zig");
const wc = contracts.workspace;

/// Terminal execution and settled cleanup are distinct Kosmos observations.
pub fn cleanupComplete(outcome: data.invocation.Outcome) bool {
    return switch (outcome) {
        .completed => true,
        .failed => |failure| std.mem.eql(u8, failure.cleanup_failures, &.{0}),
        .cancelled => |cancelled| std.mem.eql(u8, cancelled.cleanup_failures, &.{0}),
        else => false,
    };
}

pub const Profile = struct {
    id: []const u8,
    runtime_identity: state.Digest,
    /// Admitted immutable profile bytes, including concrete resource bindings.
    bytes: []const u8,
    authority: registry.Authority,
    /// Launch-owned adapter state, never persisted. Its stable address and
    /// backing allocations must outlive every joined worker using this profile.
    environment: ?*anyopaque = null,
    /// Immutable resource objects admitted with every new task. Their ordinary
    /// references are retained by the task and therefore included in archives.
    resources: []const []const u8 = &.{},
    placement: ?*const @import("../placement.zig").Configuration = null,
    semantic_construction: ?SemanticPolicy = null,

    pub fn validate(self: Profile) !void {
        _ = try name(self.id);
        _ = try name(self.authority.principal);
        if (self.authority.revoked) return error.Denied;
    }

    pub fn resourceIdentity(
        self: Profile,
        a: std.mem.Allocator,
        image: state.Digest,
    ) !state.Digest {
        const refs = try a.alloc(state.Reference, self.resources.len);
        defer a.free(refs);
        for (self.resources, refs) |bytes, *ref| ref.* = .{
            .digest = storage.digest(bytes),
            .bytes = bytes.len,
        };
        return registry.resourceIdentity(image, storage.digest(self.bytes), refs);
    }
};
pub const SemanticPolicy = @import("../configuration.zig").SemanticPolicy;
pub const FrozenInputs = struct {
    profile_id: []const u8,
    profile: []const u8,
    resources: []const []const u8,
};
pub fn readFrozenInputs(a: std.mem.Allocator, value: state.Task, source: anytype) !FrozenInputs {
    const resources = try a.alloc([]const u8, value.resources.items.len);
    var acquired: usize = 0;
    errdefer {
        for (resources[0..acquired]) |bytes| a.free(bytes);
        a.free(resources);
    }
    for (value.resources.items, resources) |reference, *bytes| {
        bytes.* = try source.object(a, reference, null);
        acquired += 1;
    }
    const profile_id = try a.dupe(u8, value.profile_id.bytes);
    errdefer a.free(profile_id);
    return .{
        .profile_id = profile_id,
        .profile = try source.object(a, value.profile, null),
        .resources = resources,
    };
}
pub const Admission = struct { receipt: state.Receipt, replayed: bool };
pub const RecoveryAvailability = struct {
    occurrence: state.Digest,
    attempt: state.Digest,
    mechanisms: []const state.RecoveryRequest,
};
pub const Status = state.Status;
pub const Work = struct {
    owner_epoch: state.Digest,
    task: state.TaskId,
    subject_work: ?state.Digest = null,
    subject_residual: ?state.Digest = null,
    operation: state.AttemptOperation = .environment,
    controller_projection: ?registry.ControllerProjection = null,
    occurrence: state.Digest,
    attempt: state.Digest,
    request: []const u8,
    prepared: ?[]const u8 = null,
    profile: []const u8 = &.{},
    entry: registry.Entry,
    cleanup: bool,
    /// A new cancellation request for this physical work, not prior task intent.
    cancel_requested: bool = false,
    recovery: ?struct { id: state.Digest, body: []const u8 } = null,
};
pub const WorkResult = union(enum) {
    acquired: []const u8,
    rederived: registry.RederivationFinding,
    not_sent,
    unknown,
    failure: anyerror,
};
pub const RecoveryCompletion =
    union(enum) { evidence: []const u8, rederived: registry.RederivationFinding };
pub const Recovered =
    union(enum) {
        capture: []const u8,
        reply: []const u8,
        not_sent,
        unsupported,
        unavailable,
        inconclusive,
        rejected,
    };
pub const Step = union(enum) { idle, progressed, waiting, work: Work };
pub const ActiveSubject =
    union(enum) { root, work: state.Digest, preparation: state.Digest, residual: state.Digest };
pub const Active = struct {
    task: state.TaskId,
    subject: ActiveSubject = .root,
    execution_revision: u64,
    realization_revision: u64 = 0,
    outer_operation: ?state.Reference = null,
    root_control: ?[]u8 = null,
    root_quantum: u64 = 0,
    root_cut_ready: bool = false,
    driver: *evaluator.Driver,
};

pub fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn operation(comptime T: type, a: std.mem.Allocator, value: T) !state.Digest {
    const bytes = try contracts.encodeOwned(T, a, value);
    defer a.free(bytes);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("agent.native.operation.v1\x00");
    hash.update(bytes);
    var result: state.Digest = undefined;
    hash.final(&result);
    return result;
}
pub fn name(bytes: []const u8) !state.Name {
    if (bytes.len == 0 or bytes.len > 128 or !std.unicode.utf8ValidateSlice(bytes))
        return error.InvalidParams;
    return .{ .bytes = bytes };
}
pub fn answerDigest(
    a: std.mem.Allocator,
    task_id: state.TaskId,
    question_id: state.Digest,
    revision: u64,
    request_digest: state.Digest,
    schema_id: []const u8,
    answer: []const u8,
) !state.Digest {
    const Request = struct {
        method: state.Method,
        task: state.TaskId,
        question: state.Digest,
        revision: u64,
        request: state.Digest,
        schema: state.Name,
        answer: contracts.Bytes(null),
    };
    return operation(
        Request,
        a,
        .{
            .method = .respond,
            .task = task_id,
            .question = question_id,
            .revision = revision,
            .request = request_digest,
            .schema = try name(schema_id),
            .answer = .{ .bytes = answer },
        },
    );
}

pub fn cancelDigest(
    a: std.mem.Allocator,
    task_id: state.TaskId,
    reason: state.Reason,
) !state.Digest {
    const Request = struct { method: state.Method, task: state.TaskId, reason: state.Reason };
    return operation(Request, a, .{ .method = .cancel, .task = task_id, .reason = reason });
}

pub fn reconcileDigest(
    a: std.mem.Allocator,
    task_id: state.TaskId,
    expected: u64,
    occurrence_id: state.Digest,
    attempt_id: state.Digest,
    recovery: state.RecoveryRequest,
) !state.Digest {
    const Request = struct {
        method: state.Method,
        task: state.TaskId,
        revision: u64,
        occurrence: state.Digest,
        attempt: state.Digest,
        recovery: state.RecoveryRequest,
    };
    return operation(Request, a, .{
        .method = .reconcile,
        .task = task_id,
        .revision = expected,
        .occurrence = occurrence_id,
        .attempt = attempt_id,
        .recovery = recovery,
    });
}

pub const PlacementKind = enum { move, control };

pub const CompilerFact = struct {
    kind: enum { program, candidate, runtime, output, guest_segment },
    input: state.Reference,
    output: state.Reference,
    context: state.Digest = @splat(0),
};

pub const SemanticRendering = union(enum) {
    source: struct { guest: state.Reference, section: wc.SemanticSection, page: wc.Page },
    value: struct { module: wc.SemanticModule, references: bool },
};

pub const SemanticReadSubject = struct { runtime: ?state.Reference, guest: state.Reference };

pub const RemoteWorkState = struct {
    latest: ?contracts.Decoded(@import("../placement.zig").ControlRecord) = null,
    pending: bool = false,
    retry_pending: ?state.Digest = null,
    pub fn deinit(self: *@This()) void {
        if (self.latest) |*saved| saved.deinit();
    }
};

pub const Ownership = enum { preserve, acquire };

pub const OccurrenceSubject = struct { image: state.Digest, cancelling: bool, cleanup: bool };

pub const ControllerHandoff =
    union(enum) { ordinary, progressed, diagnostic: contracts.controller.Diagnostic };

pub const ControllerSuccessionAdmission = struct {
    successor: state.Digest,
    converter: state.Digest,
    input: []u8,
    works: []workspace.WorkObservation,
};

pub const ControllerAdoption = struct {
    operation_id: []const u8,
    task_id: state.TaskId,
    expected_revision: u64,
    request: state.Digest,
    parent: state.Task,
    interaction: state.ControllerInteraction,
    pending: occurrence.Occurrence,
    admitted: ControllerSuccessionAdmission,
    encoded: []const u8,
    succession_id: state.Digest,
};

pub const PlacementImport = struct {
    offer: @import("../placement.zig").Signed(@import("../placement.zig").Offer),
    decision: @import("../placement.zig").Signed(@import("../placement.zig").Decision),
    peer: @import("../placement.zig").Peer,
};

pub const WorkspaceExecution = union(enum) { observation: json.Value, admitted: Admission };

pub const SemanticRuntime = struct {
    admitted: kosmos.RuntimeArtifact,
    guest: state.Reference,
    reference: ?state.Digest = null,

    pub fn deinit(value: *SemanticRuntime) void {
        value.admitted.deinit();
    }
};

pub const InteractionInput = struct { bytes: []u8, origin: ?state.Reference = null };

pub const EncodedInteraction = struct {
    input: ?InteractionInput,
    bytes: []u8,

    pub fn deinit(encoded: *EncodedInteraction, a: std.mem.Allocator) void {
        a.free(encoded.bytes);
        if (encoded.input) |input| a.free(input.bytes);
    }
};

pub const InteractionPublication = struct {
    operation_id: []const u8,
    request: state.Digest,
    parent: state.Task,
    work: workspace.Work,
    port_reference: state.Reference,
    port: workspace.Port,
    pending: occurrence.Occurrence,
    interaction: @FieldType(wc.Work, "interact"),
    encoded: EncodedInteraction,
};

pub const WorkspaceSource = union(enum) { text: []u8, value: WorkspaceValueReference };

pub const WorkspaceValueReference = struct {
    artifact: state.Reference,
    value: state.Reference,
    schema: state.Reference,
    provenance: state.Reference,
};

pub const PreparedSemanticValue = struct {
    schema: []u8,
    value: []u8,
    runtime: []u8,
    origin: workspace.SemanticSource,
    basis: contracts.Decoded(workspace.ReadObservation),

    pub fn deinit(prepared: *PreparedSemanticValue, a: std.mem.Allocator) void {
        a.free(prepared.schema);
        a.free(prepared.value);
        a.free(prepared.runtime);
        prepared.basis.deinit();
    }
};

pub const InspectionValue = struct { schema: []u8, value: []u8 };

pub const WorkspaceAdmission = struct {
    request: state.Digest,
    work: state.Digest,
    kind: @FieldType(wc.Ref, "kind"),
    observation: ?state.Reference,
};

pub const CompilerReadPosition = struct {
    occurrence: state.Digest,
    event_watermark: u64,
    controller_read: ?state.ControllerReadCut,
    root: state.RootCut,
};

pub const SelectedRuntime = struct {
    record: contracts.Decoded(workspace.Runtime),
    admitted: kosmos.RuntimeArtifact,
    pub fn deinit(self: *SelectedRuntime) void {
        self.admitted.deinit();
        self.record.deinit();
    }
};

pub const ControllerRuntimeCut = struct {
    runtime: ?state.Reference = null,
    realization_revision: u64 = 0,
};

pub const StartDelegation = struct {
    record: workspace.Delegation,
    request: state.Digest,
    policy: workspace.RunPolicy,
    command: @FieldType(wc.Work, "delegate"),
};

pub const GuardOperation = struct {
    operation_id: ?[]const u8,
    request: state.Digest,
    command: ?workspace.PublicationCommand,
};

pub const GuardRetention = struct {
    candidate: ?[]const u8 = null,
    segment: ?kosmos.RuntimeExperiment.Segment = null,
    reference: ?[]const u8 = null,
    code: ?[]const u8 = null,
};

pub const PlacementPending = struct {
    task: state.TaskId,
    id: state.Digest,
    kind: PlacementKind,
};

pub const PlacementJob = struct {
    task: state.TaskId,
    id: state.Digest,
    kind: PlacementKind,
    job: *@import("../placement_job.zig").Job,
};

pub const RuntimeCache = struct {
    epoch: u64,
    artifact: kosmos.RuntimeArtifact,
    compiled: bool = false,
};
