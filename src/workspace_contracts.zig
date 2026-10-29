//! Model actions select ordinary Horos programs and native workspace operations.
//! Text fields carry canonical runtime-schema JSON; they are never native code.
const c = @import("contracts.zig");
pub const identity = "protean-workspace/5";
pub const Ref = struct {
    kind: enum { program, work, port, value, schema, source, provenance, view, runtime, residual, candidate, controller },
    id: c.Text(64),
};
pub const Page = struct { offset: u64 = 0, maximum: u32 = 16384 };
pub const ValueInput = union(enum) {
    reference: Ref,
    inline_json: struct { schema: Ref, json_text: c.Utf8 },
};
pub const SourceInput = union(enum) { json_text: c.Utf8, reference: Ref };
pub const SourceKind = enum(u8) { source_records, component_recipe, source_derivation = 4 };
pub const ProgramRole = enum { computation, controller };
pub const NodeScope = union(enum) { all: struct {}, selected: c.Vector(u64, null) };
pub const ValueScope = union(enum) {
    none: struct {},
    nodes: NodeScope,
    fields: c.Vector(struct { node: u64, field: c.Utf8 }, null),
};
pub const Disclosure = struct {
    values: ValueScope = .{ .none = .{} },
    blobs: c.Vector(struct { blob: u64, offset: u64, length: u64 }, null) = .{ .items = &.{} },
    snapshot: bool = false,
};
pub const GuestViewSelection = struct {
    level: enum { guest_cut, outer_execution } = .guest_cut,
    expected: Expected,
    realization_revision: u64,
    nodes: NodeScope,
    disclosure: ?Disclosure = null,
};
pub const Materialization = union(enum) {
    value: ValueInput,
    snapshot: struct { path: c.Utf8, offset: u64, maximum: u64 },
    authorized_input: c.Utf8,
    guest_view: GuestViewSelection,
    semantic_source: struct {
        subject: SemanticTarget,
        module: SemanticModule,
        references: bool = false,
    },
};
pub const Policy = struct {
    stop: enum { next_slice, next_exposed_event, terminal } = .next_slice,
    continuation: enum { explicit_only, owner_scheduled } = .explicit_only,
};
pub const Expected = struct { work: Ref, execution_revision: u64, control_revision: u64 };
pub const RuntimeChoice = union(enum) { packaged: struct {}, selected: Ref };
pub const RuntimeHooks = struct { control: bool = false, storage: bool = false };
pub const ControllerCut = struct { epoch: u64, execution_revision: u64, realization_revision: u64 = 0 };
pub const SemanticTarget = union(enum) {
    runtime: Ref,
    work: struct { expected: Expected, realization_revision: u64 },
    controller: ControllerTarget,
};
pub const ControllerTarget = union(enum) {
    cut: ControllerCut,
    action: struct { interaction: c.Text(64), epoch: u64, realization_revision: u64 },
};
pub const ControllerRealizationTarget = ControllerTarget;
pub const SemanticSection = union(enum) {
    summary: struct {},
    generic: struct {},
    selected: struct {},
    helper: u32,
    evidence: struct {},
    slice: struct { function: u64 },
};
pub const SemanticModule = union(enum) {
    generic: struct {},
    selected: struct {},
    helper: u32,
    slice: struct { function: u64 },
};
pub const InspectionTarget = union(enum) {
    program: Ref,
    semantic_source: struct { subject: SemanticTarget, section: SemanticSection },
    consumer: struct { program: Ref, function: u64, binding: u64 },
};
pub const Exposure = struct { effect: u64, class: enum { observation, input, alternative } };
pub const Interpretation = union(enum) {
    none: struct {},
    model: struct { port: Ref, generation: u64, profile_id: c.Text(64), effort: c.Text(16), subproblem: c.Utf8, inputs: c.Vector(Ref, null) },
    snapshot: struct { port: Ref, generation: u64, path: c.Utf8, offset: u64, maximum: u64 },
};
pub const Adoption = struct {
    successor: Ref,
    converter: Ref,
    expected_controller_epoch: u64,
    expected_handoff_identity: c.Text(64),
    trial: union(enum) { none: struct {}, selected: Ref } = .{ .none = .{} },
    reason: c.Text(256),
};
pub const Program = union(enum) {
    describe: struct { section: enum { source_records, values, components, examples, bindings, runtimes, retention_query, divergence_query, hypothetical_reply, controller_contract, current_controller, semantic_candidates, source_derivations }, page: Page },
    build: struct { source: SourceInput, source_kind: SourceKind, exposures: c.Vector(Exposure, null), role: ProgramRole = .computation },
    inspect: struct { target: InspectionTarget, page: Page },
    specialize: struct { program: Ref, hooks: RuntimeHooks = .{} },
    derive: struct { ancestor: SemanticTarget, program: Ref, proposal: SourceInput },
    validate: struct { candidate: Ref },
    adopt: Adoption,
};
pub const ValidationOutcome = enum {
    validated,
    rejected,
    unsupported_relation,
    resource_exhausted,
    interrupted,
    unavailable_dependency,
};
pub const Trial = union(enum) { none: struct {}, synthetic: struct { responses: c.Vector(struct { identity: c.Utf8, payload: Ref, response: Ref }, null), live_inference: bool = false } };
pub const ObserverPolicy = struct {
    delivery: enum { sampled, lossless } = .sampled,
    cadence: u64 = 1,
    granularity: enum { publication, one_guest_step } = .publication,
    continuation: enum { explicit_only, owner_scheduled } = .explicit_only,
};
pub const Observe = struct {
    program: Ref,
    source: GuestViewSelection,
    accumulator: Ref,
    policy: ObserverPolicy = .{},
    previous: ?Ref = null,
};
pub const Work = union(enum) {
    observe: Observe,
    stop_observing: Expected,
    start: struct { program: Ref, input: ValueInput, policy: Policy, runtime: RuntimeChoice = .{ .packaged = .{} }, trial: Trial = .{ .none = .{} } },
    inspect: struct { work: Ref },
    advance: Expected,
    /// Bound physical evaluator progress without claiming a new guest cut.
    pump: struct { expected: Expected, base_quantum: u64 = 65536 },
    delegate: struct { expected: Expected, policy: Policy, interpretation: Interpretation = .{ .none = .{} } },
    wait: struct { works: c.Vector(Ref, null), after: u64 },
    interact: struct { expected: Expected, port: Ref, generation: u64, command: union(enum) { resume_value: ValueInput, finish: struct {} } },
    collect: struct { works: c.Vector(Ref, null) },
    park: Expected,
    cancel: struct { expected: Expected, reason: c.Text(256) },
    realize: struct { expected: Expected, realization_revision: u64, runtime: RuntimeChoice },
    realize_controller: struct { expected: ControllerRealizationTarget, runtime: RuntimeChoice },
    guard: struct { expected: Expected, realization_revision: u64, candidate: Ref },
    unguard: struct { expected: Expected, guard_revision: u64 },
    request_cut: struct { expected: Expected, level: enum { guest_cut, outer_execution } },
};
pub const Context = union(enum) {
    inspect: struct { page: Page },
    materialize: struct { input: Materialization, sources: c.Vector(Ref, null) },
    select: struct { values: c.Vector(Ref, null) },
    expand: struct { reference: Ref, page: Page },
};
pub const PlacementSubject = union(enum) { controller: struct {}, work: Ref };
pub const Placement = union(enum) {
    sites: struct {},
    inspect: PlacementSubject,
    assess: struct { subject: PlacementSubject, site: c.Text(128) },
    /// Names an idempotent move of the current owned continuation. Controller
    /// movement occurs after this action's reply is durably captured.
    move: struct { operation: c.Text(128), subject: PlacementSubject, site: c.Text(128), custody_epoch: u64 },
    retry: struct { operation: c.Text(128) },
    withdraw: struct { operation: c.Text(128) },
    control: struct { operation: c.Text(128), command: Work },
    expand: struct { operation: c.Text(128), work: Ref, reference: Ref, page: Page },
};
pub const Command = union(enum) { program: Program, work: Work, context: Context, placement: Placement };
/// Full observations remain retained; only the requested page enters inference.
/// A rejection is ordinary result data and never changes the next action set.
pub const Reply = struct {
    disposition: enum { observed, admitted, rejected },
    observation_json: c.Utf8,
    selected_view: ?Ref = null,
    program: ?Ref = null,
    evidence: ?Ref = null,
};
