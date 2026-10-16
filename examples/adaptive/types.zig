//! One application state and the additive adaptive Responses contract.
const protean = @import("protean");
const std = @import("std");
const contracts = @import("protean_contracts");
pub const tool_types = @import("tool_types.zig");
pub const controls = protean.adaptive_controls;
pub const model = protean.model_invocation;
pub const application_id = "adaptive-agent";
pub const application_version = "5.0.0";
pub const input_schema_id = "adaptive-agent.input.v2";
pub const output_schema_id = "adaptive-agent.output.v5";
pub const failure_schema_id = "adaptive-agent.failure.v1";
pub const message_schema_id = "adaptive-agent.message.v2";
pub const answer_schema_id = "adaptive-agent.answer.v2";
pub const bindings_identity = "agent.adaptive.bindings.v2";
pub const prepare_identity = "agent.adaptive.context.prepare.v2";
pub const work_identity = "agent.adaptive.snapshot.work.v2";
pub const inspect_identity = "agent.adaptive.snapshot.guards.v2";
pub const workspace_identity = "agent.adaptive.workspace.v1";
pub const question_identity = "agent.adaptive.question.v2";
pub const Path = contracts.Utf8;
pub const Summary = contracts.Utf8;
pub const Input = struct { task: Summary };
pub const Message = struct { message: Summary };
pub const Answer = Message;
pub const Question = struct { prompt: contracts.Utf8 };
pub const Failure = enum { capacity, invalid_response, invalid_evidence };
pub const Claim = struct {
    kind: enum { observation, inference, hypothesis },
    statement: contracts.Utf8,
    reasoning: contracts.Utf8,
    evidence_indices: contracts.Vector(u64, null),
};
pub const Report = struct {
    summary: Summary,
    claims: contracts.Vector(Claim, null),
    limitations: contracts.Vector(contracts.Utf8, null),
};
pub const ReportRejection = struct {
    reason: enum { empty_report, empty_summary, empty_statement, missing_reasoning, missing_evidence, out_of_range, duplicate_evidence },
    claim_index: ?u64,
    evidence_position: ?u64,
};
pub const Result = union(enum) { report: Report, no_result: Summary, refusal: Summary, capacity: Summary };
pub const Action = union(enum) {
    list: struct { prefix: Path, after: Path },
    read: struct { path: Path, start: u64, maximum: u32 },
    ask: struct { question: contracts.Utf8 },
    report: Report,
    stop: struct { reason: contracts.Text(256) },
    inference_set: controls.InferenceSet,
    skill_set: controls.SkillSet,
    inspect: struct { evidence_index: u64 },
    program: struct { command: contracts.workspace.Program },
    work: struct { command: contracts.workspace.Work },
    context: struct { command: contracts.workspace.Context },
};
pub const P = model.Profile(Action, .{
    .{ .name = "list", .description = "List a page of the admitted immutable snapshot; next is the following page's after." },
    .{ .name = "read", .description = "Read at most 4096 UTF-8 bytes. Successful reads append zero-indexed evidence." },
    .{ .name = "ask", .description = "Ask for clarification needed for the current task.", .context_retention = .control },
    .{ .name = "report", .description = "Finish with claims citing acquired evidence_indices, reasoning, and limitations. Observations and inferences require citations; inferences and hypotheses require reasoning." },
    .{ .name = "stop", .description = "Stop honestly if the task cannot be supported by the admitted evidence." },
    .{ .name = "inference_set", .description = "Select an approved profile and effort for the next inference, using the current control revision.", .context_retention = .control },
    .{ .name = "skill_set", .description = "Load, deactivate or physically unload a pinned approved skill. Use an exact version and current control revision.", .context_retention = .control },
    .{ .name = "inspect", .description = "Locate guard-like lines in source-file evidence by its global evidence_index. Generated results are not source files. Requires an active invariant-review skill; it is not a correctness proof." },
    .{ .name = "program", .description = "Describe the existing Horos source-record contract, construct a general program, or inspect its real interface. Construction never runs the algorithm or invokes another model." },
    .{ .name = "work", .description = "Start, inspect, advance, delegate, wait for, interact with, collect, park, or cancel retained computation. A pending child input never restricts your next action." },
    .{ .name = "context", .description = "Inspect and materialize authorized evidence, choose a view for future inference, or expand an omitted source range. Views preserve sources and coverage." },
}, .{});
pub fn ordinal(comptime name: []const u8) usize {
    return @backingInt(@field(std.meta.Tag(Action), name));
}
pub fn toolMask(comptime names: anytype) [P.declaration_count]bool {
    var result: [P.declaration_count]bool = @splat(false);
    inline for (names) |name| result[ordinal(name)] = true;
    return result;
}
pub const PolicyView = struct { profiles: controls.Profiles, catalog: controls.Catalog };
pub const Bindings = struct {
    policy: [32]u8,
    snapshot: [32]u8,
    files: u64,
    excluded_entries: u64,
    profiles: controls.Profiles,
    catalog: controls.Catalog,
    initial: controls.State,
    instructions: P.MessageText,
    status: P.MessageText,
};
// These retain the fixed example's snapshot-query wire shapes so both use the
// same native repository query implementation, with separate effect identities.
pub const ListRequest = @FieldType(Action, "list");
pub const ReadRequest = @FieldType(Action, "read");
pub const ListEntry = struct { path: Path, bytes: u64 };
pub const Listing = struct { entries: contracts.Vector(ListEntry, 32), truncated: bool, next: Path };
pub const Evidence = struct { snapshot: [32]u8, path: Path, sha256: contracts.Text(64), start: u64, end: u64, file_bytes: u64, content: contracts.Text(4096) };
pub const ReadResult = union(enum) { found: Evidence, missing: Path, invalid: contracts.Text(128) };
pub const ListObservation = struct { value: Listing, model_text: P.ResultText };
pub const ReadObservation = struct { value: ReadResult, model_text: P.ResultText };
pub const SourceEvidenceReference = struct { object: model.ArtifactReference, snapshot: [32]u8, path: Path, sha256: contracts.Text(64), start: u64, end: u64, file_bytes: u64 };
pub const EvidenceReference = union(enum) { source: SourceEvidenceReference, workspace: contracts.workspace.Ref };
pub const EvidenceList = contracts.Vector(EvidenceReference, null);
pub const WorkOutcome = union(enum) {
    list: struct { request: ListRequest, result: Listing },
    read: struct { request: ReadRequest, result: union(enum) { found: Evidence, missing: Path, invalid: contracts.Text(128) } },
    ask: struct { question: Question, answer: Answer },
    inspect: struct { evidence_index: u64, guard_count: u32 },
};
pub const WorkRequest = struct {
    context: model.AdaptiveContextReference,
    call_id: P.CallId,
    action: union(enum) { list: ListRequest, read: ReadRequest, inspect: struct { evidence_index: u64, evidence: SourceEvidenceReference } },
};
pub const WorkArtifact = struct { version: u8, task: [16]u8, policy: [32]u8, context: model.AdaptiveContextReference, call_id: P.CallId, request: @FieldType(WorkRequest, "action"), outcome: WorkOutcome, evidence: ?Evidence, model_text: P.ResultText };
pub const WorkReply = struct { artifact: model.ArtifactReference, evidence: ?SourceEvidenceReference };
pub const WorkspaceRequest = struct { context: model.AdaptiveContextReference, call_id: P.CallId, action: contracts.workspace.Command };
pub const Programs = contracts.Vector(contracts.workspace.Ref, null);
pub const WorkspaceResult = struct { reply: contracts.workspace.Reply, evidence_index: ?u64 };
pub const ResultValue = union(enum) { inline_text: Summary, work: model.ArtifactReference, control: model.ArtifactReference, report_rejection: ReportRejection, workspace: WorkspaceResult };
pub const PendingResult = struct { call_id: P.CallId, output: ResultValue };
pub const PendingResults = contracts.Vector(PendingResult, 1);
pub const ControlReceipt = struct {
    task: [16]u8,
    source: model.ArtifactReference,
    call_id: P.CallId,
    previous_revision: u64,
    next_revision: u64,
    disposition: enum { admitted, unchanged, rejected },
    rejection: controls.Rejection,
    previous_profile: contracts.Text(64),
    next_profile: contracts.Text(64),
    previous_model: contracts.Text(128),
    next_model: contracts.Text(128),
    previous_effort: @FieldType(model.AdaptiveSelection, "effective_effort"),
    next_effort: @FieldType(model.AdaptiveSelection, "effective_effort"),
    context_epoch: u64,
    eviction_generation: u64,
};
pub const ReceiptReference = struct { object: model.ArtifactReference, previous_revision: u64, next_revision: u64, disposition: @FieldType(ControlReceipt, "disposition"), rejection: controls.Rejection, next_profile: contracts.Text(64), next_effort: @FieldType(ControlReceipt, "next_effort"), context_epoch: u64, eviction_generation: u64 };
pub const ReceiptArtifact = struct { receipt: ControlReceipt, model_text: P.ResultText };
pub const Receipts = contracts.Vector(ReceiptReference, null);
pub const State = struct {
    task: Summary,
    control: controls.State,
    replay: ?model.AdaptiveContextReference,
    results: PendingResults,
    messages: P.Messages,
    evidence: EvidenceList,
    programs: Programs,
    receipts: Receipts,
    model_calls: u64,
    work_calls: u64,
    selected_view: ?contracts.workspace.Ref = null,
    selected_view_at: u64 = 0,
};
pub const Output = struct {
    result: Result,
    evidence: EvidenceList,
    programs: Programs,
    control: controls.State,
    receipts: Receipts,
    model_calls: u64,
    work_calls: u64,
};
pub const ControlSubject = struct {
    call_id: P.CallId,
    reason: contracts.Text(256),
    proposal: controls.Proposal,
};
pub const Preparation = struct {
    state: State,
    offered: [P.declaration_count]bool,
    control: ?ControlSubject,
};
pub const Ready = struct {
    request: P.AdaptiveRequest,
    receipt: ?ReceiptReference,
    results: PendingResults,
};
pub const PreparationResult = union(enum) { ready: Ready, rejected: controls.Rejection };
pub const PreparationProduct = struct { result: PreparationResult, receipt: ?contracts.Bytes(null) };
pub const PreparationCapture = struct { prepared: [32]u8 };
// Version 3 removes cumulative quotas. These eight declaration bits retain
// their named authority mapping; construction policy is admitted separately.
pub const SkillConfig = struct { id: contracts.Text(64), version: contracts.Text(64), description: contracts.Text(256), markdown: contracts.Text(4096), tools: [8]bool };
pub const Configuration = struct { workspace: contracts.Text(128), snapshot_root: contracts.Text(4096), endpoint: contracts.Text(2048), audience: contracts.Text(128), profiles: @FieldType(P.AdaptivePolicy, "profiles"), initial_profile: contracts.Text(64), initial_effort: @FieldType(model.AdaptiveSelection, "effective_effort"), skills: contracts.Vector(SkillConfig, null) };
pub const DataRow = struct { id: u64, key: u64, value: u64, group: u64 };
pub const DataRows = contracts.Vector(DataRow, null);
pub const ToolInputConfig = struct { id: contracts.Text(64), description: contracts.Text(256), rows: DataRows, relation: DataRows, selected: tool_types.Keys };
pub const ToolConfiguration = struct { build: bool, run: bool, inputs: contracts.Vector(ToolInputConfig, null) };
pub const ConfigurationV3 = struct { schema: contracts.Text(64), adaptive: Configuration, tools: ?ToolConfiguration };
pub const ToolInputReference = struct { id: contracts.Text(64), description: contracts.Text(256), object: model.ArtifactReference };
pub const ToolPolicy = struct { build: bool, run: bool, catalog: model.ArtifactReference, inputs: contracts.Vector(ToolInputReference, null) };
// Ordinary wire contracts accompany the emitted Horos image. External
// inspection tools can decode them without an adaptive execution implementation.
pub const support_types = .{
    .{ .name = "Unit", .T = void },
    .{ .name = "Message", .T = Message },
    .{ .name = "Failure", .T = Failure },
    .{ .name = "Configuration", .T = Configuration },
    .{ .name = "ConfigurationV3", .T = ConfigurationV3 },
    .{ .name = "Bindings", .T = Bindings },
    .{ .name = "Preparation", .T = Preparation },
    .{ .name = "PreparationResult", .T = PreparationResult },
    .{ .name = "PreparationProduct", .T = PreparationProduct },
    .{ .name = "PreparationCapture", .T = PreparationCapture },
    .{ .name = "ControlReceipt", .T = ControlReceipt },
    .{ .name = "ControlState", .T = controls.State },
    .{ .name = "Snapshot", .T = contracts.RepositorySnapshot },
    .{ .name = "Listing", .T = Listing },
    .{ .name = "ReadResult", .T = ReadResult },
    .{ .name = "WorkRequest", .T = WorkRequest },
    .{ .name = "WorkReply", .T = WorkReply },
    .{ .name = "WorkArtifact", .T = WorkArtifact },
    .{ .name = "WorkspaceRequest", .T = WorkspaceRequest },
    .{ .name = "WorkspaceReply", .T = contracts.workspace.Reply },
    .{ .name = "ToolInput", .T = contracts.tool_construction.Input },
    .{ .name = "ReceiptArtifact", .T = ReceiptArtifact },
    .{ .name = "Question", .T = Question },
    .{ .name = "Answer", .T = Answer },
    .{ .name = "Action", .T = Action },
    .{ .name = "Claim", .T = Claim },
    .{ .name = "Report", .T = Report },
    .{ .name = "ReportRejection", .T = ReportRejection },
    .{ .name = "Invocation", .T = P.Request },
    .{ .name = "Tools", .T = P.Tools },
    .{ .name = "NormalizationLimits", .T = model.NormalizationLimits },
    .{ .name = "MaximumAdaptiveReplyBytes", .T = u32 },
    .{ .name = "ModelResult", .T = P.Result },
    .{ .name = "CapturedResponse", .T = model.CapturedResponse },
    .{ .name = "AdaptiveRequest", .T = P.AdaptiveRequest },
    .{ .name = "AdaptiveResult", .T = P.AdaptiveResult },
    .{ .name = "AdaptiveContext", .T = P.AdaptiveContext },
    .{ .name = "HistoryChunk", .T = P.HistoryChunk },
    .{ .name = "AdaptivePrepared", .T = P.AdaptivePrepared },
    .{ .name = "Policy", .T = P.AdaptivePolicy },
    .{ .name = "Profile", .T = model.AdaptiveInferenceProfile },
    .{ .name = "Catalog", .T = P.AdaptiveCatalog },
    .{ .name = "Input", .T = Input },
    .{ .name = "Output", .T = Output },
    .{ .name = "Inbox", .T = protean.inbox.Profile(Message).Reply },
};
