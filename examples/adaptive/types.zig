//! One application state and the additive adaptive Responses contract.
const protean = @import("protean");
const std = @import("std");
const contracts = @import("protean_contracts");
pub const tool_types = @import("tool_types.zig");
pub const controls = protean.adaptive_controls;
pub const model = protean.model_invocation;
pub const application_id = "adaptive-agent";
pub const application_version = "2.0.0";
pub const input_schema_id = "adaptive-agent.input.v1";
pub const output_schema_id = "adaptive-agent.output.v2";
pub const failure_schema_id = "adaptive-agent.failure.v1";
pub const message_schema_id = "adaptive-agent.message.v1";
pub const answer_schema_id = "adaptive-agent.answer.v1";
pub const bindings_identity = "agent.adaptive.bindings.v1";
pub const prepare_identity = "agent.adaptive.context.prepare.v1";
pub const work_identity = "agent.adaptive.snapshot.work.v1";
pub const inspect_identity = "agent.adaptive.snapshot.guards.v1";
pub const tool_build_identity = "agent.adaptive.tool.build.v1";
pub const tool_run_identity = "agent.adaptive.tool.run.v1";
pub const question_identity = "agent.adaptive.question.v1";
pub const Path = contracts.Text(256);
pub const Summary = contracts.Text(2048);
pub const Input = struct { task: Summary };
pub const Message = struct { message: Summary };
pub const Answer = Message;
pub const Question = struct { prompt: contracts.Text(512) };
pub const Failure = enum { capacity, invalid_response, invalid_evidence };
pub const Action = union(enum) {
    list: struct { prefix: Path, after: Path },
    read: struct { path: Path, start: u64, maximum: u32 },
    ask: struct { question: contracts.Text(512) },
    report: struct { summary: Summary, evidence_index: u64 },
    stop: struct { reason: contracts.Text(256) },
    inference_set: controls.InferenceSet,
    skill_set: controls.SkillSet,
    inspect: struct { evidence_index: u64 },
    // The inherited 16-KiB argument envelope reserves worst-case JSON escaping.
    // Native construction's 8-KiB ceiling remains an upper bound, not a promise
    // that every such string fits this stricter model interface.
    tool_build: struct { proposal_json: contracts.Text(2700) },
    tool_run: struct { tool_ref: contracts.Text(96), input_ref: contracts.Text(96) },
};
pub const P = model.Profile(Action, .{
    .{ .name = "list", .description = "List a page of the admitted immutable snapshot; next is the following page's after." },
    .{ .name = "read", .description = "Read at most 4096 UTF-8 bytes. Successful reads append zero-indexed evidence." },
    .{ .name = "ask", .description = "Ask for clarification needed for the current task. A task admits at most four answers and follow-ups in total." },
    .{ .name = "report", .description = "Finish with a grounded summary and one acquired evidence_index." },
    .{ .name = "stop", .description = "Stop honestly if the task cannot be supported by the admitted evidence." },
    .{ .name = "inference_set", .description = "Select an approved profile and effort for the next inference, using the current control revision." },
    .{ .name = "skill_set", .description = "Load, deactivate or physically unload a pinned approved skill. Use an exact version and current control revision." },
    .{ .name = "inspect", .description = "Locate guard-like lines in source-file evidence by its global evidence_index. Generated results are not source files. Requires an active invariant-review skill; it is not a correctness proof." },
    .{ .name = "tool_build", .description = "Construct a pure Horos program from a closed JSON link recipe over the admitted component catalog. Construction does not execute it or establish task correctness." },
    .{ .name = "tool_run", .description = "Run an admitted generated program on one authorized compatible input reference through native Kronos." },
}, .{ .model_id_bytes = 128, .temperature_bytes = 32, .maximum_messages = 4, .message_bytes = model.maximum_adaptive_request_bytes, .maximum_output_items = 8, .call_id_bytes = 128, .arguments_json_bytes = 16384, .result_text_bytes = 32768, .provider_response_bytes = 512 * 1024, .maximum_adaptive_reply_bytes = 16 * 1024 });
pub fn ordinal(comptime name: []const u8) usize {
    return @backingInt(@field(std.meta.Tag(Action), name));
}
pub fn toolMask(comptime names: anytype) [P.declaration_count]bool {
    var result: [P.declaration_count]bool = @splat(false);
    inline for (names) |name| result[ordinal(name)] = true;
    return result;
}
pub const PolicyView = struct { profiles: controls.Profiles, catalog: controls.Catalog, maximum_model_calls: u16, maximum_revision: u64 };
pub const Bindings = struct {
    policy: [32]u8,
    snapshot: [32]u8,
    files: u32,
    excluded_entries: u32,
    profiles: controls.Profiles,
    catalog: controls.Catalog,
    initial: controls.State,
    maximum_model_calls: u16,
    maximum_revision: u64,
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
pub const GeneratedEvidenceReference = struct { object: model.ArtifactReference, program: model.ArtifactReference, input: model.ArtifactReference };
pub const EvidenceReference = union(enum) { source: SourceEvidenceReference, generated: GeneratedEvidenceReference };
pub const EvidenceList = contracts.Vector(EvidenceReference, 8);
pub const Followups = contracts.Vector(Summary, 4);
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
pub const ToolRequest = struct {
    context: model.AdaptiveContextReference,
    call_id: P.CallId,
    action: union(enum) { build: @FieldType(Action, "tool_build"), run: @FieldType(Action, "tool_run") },
};
pub const ToolFailure = struct { stage: enum { admission, recipe, construction, execution }, reason: contracts.Text(128) };
pub const ToolArtifact = struct {
    task: [16]u8,
    policy: [32]u8,
    call_id: P.CallId,
    outcome: union(enum) {
        built: model.ArtifactReference,
        ran: struct { program: model.ArtifactReference, input: model.ArtifactReference, value: contracts.Bytes(32768) },
        rejected: ToolFailure,
    },
    model_text: P.ResultText,
};
pub const ToolReply = struct { artifact: model.ArtifactReference, program: ?model.ArtifactReference, evidence: ?GeneratedEvidenceReference };
pub const Programs = contracts.Vector(model.ArtifactReference, 4);
pub const ResultValue = union(enum) { inline_text: Summary, work: model.ArtifactReference, control: model.ArtifactReference, tool: model.ArtifactReference };
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
pub const Receipts = contracts.Vector(ReceiptReference, 16);
pub const State = struct {
    task: Summary,
    followups: Followups,
    control: controls.State,
    replay: ?model.AdaptiveContextReference,
    results: PendingResults,
    messages: P.Messages,
    evidence: EvidenceList,
    programs: Programs,
    receipts: Receipts,
    model_calls: u16,
    work_calls: u16,
};
pub const Output = struct {
    disposition: enum { report, no_result, refusal, capacity },
    summary: Summary,
    evidence: EvidenceList,
    programs: Programs,
    control: controls.State,
    receipts: Receipts,
    model_calls: u16,
    work_calls: u16,
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
pub const PreparationProduct = struct { result: PreparationResult, receipt: ?contracts.Bytes(128 * 1024) };
pub const PreparationCapture = struct { prepared: [32]u8, build_exhausted: bool, run_exhausted: bool };
// The original configuration keeps its eight declaration bits. Version 2 adds
// explicit construction policy; admission maps these original bits by name.
pub const SkillConfig = struct { id: contracts.Text(64), version: contracts.Text(64), description: contracts.Text(256), markdown: contracts.Text(4096), tools: [8]bool };
pub const Configuration = struct { workspace: contracts.Text(128), snapshot_root: contracts.Text(4096), endpoint: contracts.Text(2048), audience: contracts.Text(128), profiles: @FieldType(P.AdaptivePolicy, "profiles"), initial_profile: contracts.Text(64), initial_effort: @FieldType(model.AdaptiveSelection, "effective_effort"), skills: contracts.Vector(SkillConfig, 32), maximum_model_calls: u16, maximum_control_revision: u16 };
pub const DataRow = struct { id: u64, key: u64, value: u64, group: u64 };
pub const DataRows = contracts.Vector(DataRow, 32);
pub const ToolInputConfig = struct { id: contracts.Text(64), description: contracts.Text(256), rows: DataRows, relation: DataRows, selected: tool_types.Keys };
pub const ToolConfiguration = struct { build: bool, run: bool, inputs: contracts.Vector(ToolInputConfig, 4) };
pub const ConfigurationV2 = struct { schema: contracts.Text(64), adaptive: Configuration, tools: ToolConfiguration };
pub const ToolInputReference = struct { id: contracts.Text(64), description: contracts.Text(256), object: model.ArtifactReference };
pub const ToolPolicy = struct { build: bool, run: bool, catalog: model.ArtifactReference, inputs: contracts.Vector(ToolInputReference, 4) };
// Ordinary wire contracts accompany the emitted Horos image. External
// inspection tools can decode them without an adaptive execution implementation.
pub const support_types = .{
    .{ .name = "Unit", .T = void },
    .{ .name = "Message", .T = Message },
    .{ .name = "Failure", .T = Failure },
    .{ .name = "Configuration", .T = Configuration },
    .{ .name = "ConfigurationV2", .T = ConfigurationV2 },
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
    .{ .name = "ToolRequest", .T = ToolRequest },
    .{ .name = "ToolReply", .T = ToolReply },
    .{ .name = "ToolArtifact", .T = ToolArtifact },
    .{ .name = "ToolProgram", .T = contracts.tool_construction.Program },
    .{ .name = "ToolInput", .T = contracts.tool_construction.Input },
    .{ .name = "ReceiptArtifact", .T = ReceiptArtifact },
    .{ .name = "Question", .T = Question },
    .{ .name = "Answer", .T = Answer },
    .{ .name = "Action", .T = Action },
    .{ .name = "Invocation", .T = P.Request },
    .{ .name = "Tools", .T = P.Tools },
    .{ .name = "NormalizationLimits", .T = model.NormalizationLimits },
    .{ .name = "MaximumAdaptiveReplyBytes", .T = u32 },
    .{ .name = "ModelResult", .T = P.Result },
    .{ .name = "CapturedResponse", .T = model.CapturedResponse },
    .{ .name = "AdaptiveRequest", .T = P.AdaptiveRequest },
    .{ .name = "AdaptiveResult", .T = P.AdaptiveResult },
    .{ .name = "AdaptiveContext", .T = P.AdaptiveContext },
    .{ .name = "AdaptivePrepared", .T = P.AdaptivePrepared },
    .{ .name = "Policy", .T = P.AdaptivePolicy },
    .{ .name = "Profile", .T = model.AdaptiveInferenceProfile },
    .{ .name = "Catalog", .T = P.AdaptiveCatalog },
    .{ .name = "Input", .T = Input },
    .{ .name = "Output", .T = Output },
    .{ .name = "Inbox", .T = protean.inbox.Profile(Message).Reply },
};
