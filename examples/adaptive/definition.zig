//! One authored investigation with model-callable adaptive control.
const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const a = horos.authoring;
const t = @import("application_types");
const P = t.P;
const retained_calls: t.model.RetainedCalls = .{ .items = &.{ .{ .bytes = "ask" }, .{ .bytes = "inference_set" }, .{ .bytes = "skill_set" }, .{ .bytes = "program" } } };
const native = horos.data.schema.native;
fn V(comptime T: type) type {
    return *const a.Value(a.Shape(T));
}
fn Op(comptime Input: type, comptime Output: type) type {
    return *const a.Operation(a.OperationSignature(a.Shape(Input), a.Shape(Output), native.Fields(&.{}, &.{})));
}
fn F(comptime Input: type, comptime Output: type) type {
    return *const a.Function(a.Signature(a.Shape(Input).contract.product, a.Shape(Output)));
}
const Inbox = protean.inbox.Profile(t.Message);
pub const capabilities = .{
    .{ .identity = t.bindings_identity, .resource_role = "snapshot", .controller_import = .task_view },
    .{ .identity = t.prepare_identity, .resource_role = "context", .controller_import = .context },
    .{ .identity = t.work_identity, .resource_role = "snapshot", .controller_import = .snapshot },
    .{ .identity = t.inspect_identity, .resource_role = "invariant-review", .controller_import = .inspect },
    .{ .identity = t.workspace_identity, .resource_role = "workspace", .controller_import = .workspace },
    .{ .identity = t.question_identity, .resource_role = "user", .controller_import = .question },
    .{ .identity = protean.inbox.semantic_identity, .resource_role = "user", .controller_import = .inbox },
    .{ .identity = P.identity, .resource_role = "inference", .controller_import = .deliberate },
};
pub const resources = .{
    .{ .id = "adaptive-agent.instructions", .version = "1", .media_type = "text/plain", .bytes = @embedFile("instructions.txt") },
    .{ .id = "adaptive-agent.offline-responses", .version = "1", .media_type = "application/json", .bytes = @embedFile("offline-responses.json") },
    .{ .id = "repository-orientation", .version = "1", .media_type = "text/markdown", .bytes = @embedFile("skills/orientation.md") },
    .{ .id = "invariant-review", .version = "1", .media_type = "text/markdown", .bytes = @embedFile("skills/invariant-review.md") },
    .{ .id = "technical-reporting", .version = "1", .media_type = "text/markdown", .bytes = @embedFile("skills/technical-reporting.md") },
    .{ .id = "tool-construction", .version = "1", .media_type = "text/markdown", .bytes = @embedFile("skills/tool-construction/SKILL.md") },
};
pub fn generatedResources(allocator: std.mem.Allocator) ![1]struct { id: []const u8, version: []const u8, media_type: []const u8, bytes: []const u8 } {
    return .{.{ .id = "tool-construction.catalog", .version = "1", .media_type = "application/octet-stream", .bytes = try @import("tool_catalog.zig").catalog(allocator) }};
}
pub const System = protean.system(.{ .InitialArgs = t.Input, .Result = t.Output, .Failure = t.Failure, .application = Application });
pub const ControllerSystem = protean.system(.{ .InitialArgs = t.ControllerInput, .Result = t.Output, .Failure = t.Failure, .application = ControllerApplication });
const ControllerApplication = struct {
    pub fn emit(context: protean.Context) !horos.source.Module {
        return Application.emitMode(context, true);
    }
};

const Emit = struct {
    context: protean.Context,
    author: *a.Context,
    fn failure(e: Emit) !*const a.FailureLiteral(a.Shape(t.Failure)) {
        return a.interop.literalFailure(e.author, try e.context.literal(t.Failure, .capacity));
    }
    fn widen(e: Emit, b: anytype, comptime T: type, value: anytype) !V(T) {
        return b.blobConcat(try e.context.schema(T), try e.context.literal(T, .{ .bytes = "" }), value, try e.failure());
    }
    fn finish(e: Emit, b: anytype, state: V(t.State), comptime kind: std.meta.Tag(t.Result), value: anytype) !V(t.Output) {
        return b.product(try e.context.schema(t.Output), .{ .result = try b.variant(try e.context.schema(t.Result), @tagName(kind), value), .evidence = try b.field(state, "evidence"), .programs = try b.field(state, "programs"), .control = try b.field(state, "control"), .receipts = try b.field(state, "receipts"), .model_calls = try b.field(state, "model_calls"), .work_calls = try b.field(state, "work_calls") });
    }
    fn message(e: Emit, b: anytype, role: protean.model_invocation.MessageRole, text: V(P.MessageText)) !V(P.Message) {
        return b.product(try e.context.schema(P.Message), .{ .role = try e.context.literal(protean.model_invocation.MessageRole, role), .content = text });
    }
};

fn Ops(comptime controller: bool) type {
    return struct {
        bindings: Op(void, t.Bindings),
        prepare: Op(t.Preparation, t.PreparationResult),
        work: Op(t.WorkRequest, t.WorkReply),
        ask: Op(t.Question, t.Answer),
        inspect: Op(t.WorkRequest, t.WorkReply),
        workspace: Op(t.WorkspaceRequest, @import("protean_contracts").workspace.Reply),
        inbox: Op(void, Inbox.Reply),
        model: Op(if (controller) protean.responders.ControllerRequest(P, t.ControllerCarry) else P.AdaptiveRequest, if (controller) @import("protean_contracts").controller.Reply(P.AdaptiveResult) else P.AdaptiveResult),
    };
}
const Application = struct {
    pub fn emit(context: protean.Context) !horos.source.Module {
        return emitMode(context, false);
    }
    fn emitMode(context: protean.Context, comptime controller: bool) !horos.source.Module {
        const c = context.author;
        errdefer {
            const diagnostic = c.lastDiagnostic();
            std.log.err("adaptive authoring: {s}", .{diagnostic.renderAlloc(context.builder.allocator()) catch "diagnostic unavailable"});
        }
        const e: Emit = .{ .context = context, .author = c };
        const ops: Ops(controller) = .{
            .bindings = try context.external(t.bindings_identity, try context.schema(void), try context.schema(t.Bindings), .read),
            .prepare = try context.external(t.prepare_identity, try context.schema(t.Preparation), try context.schema(t.PreparationResult), .read),
            .work = try context.external(t.work_identity, try context.schema(t.WorkRequest), try context.schema(t.WorkReply), .read),
            .ask = try context.external(t.question_identity, try context.schema(t.Question), try context.schema(t.Answer), .read),
            .inspect = try context.external(t.inspect_identity, try context.schema(t.WorkRequest), try context.schema(t.WorkReply), .read),
            .workspace = try context.external(t.workspace_identity, try context.schema(t.WorkspaceRequest), try context.schema(@import("protean_contracts").workspace.Reply), .read),
            .inbox = try Inbox.declare(context),
            .model = if (controller) try protean.responders.controllerModelOperation(P, t.ControllerCarry, context) else try a.interop.externalOperation(c, try P.declare(context.builder), try context.schema(P.AdaptiveRequest), try context.schema(P.AdaptiveResult)),
        };
        const loop = try c.function("adaptive repository investigation", .{ .bindings = try e.context.schema(t.PolicyView), .state = try e.context.schema(t.State) }, try e.context.schema(t.Output), .{ ops.prepare, ops.work, ops.ask, ops.inspect, ops.workspace, ops.inbox, ops.model });
        const program: Program(controller) = .{
            .e = e,
            .ops = ops,
            .loop = loop,
            .report = try @import("report.zig").define(context),
            .source_at = try c.function("source evidence at global index", .{ .evidence = try e.context.schema(t.EvidenceList), .index = try e.context.schema(u64) }, try e.context.schema(?t.SourceEvidenceReference), &.{}),
            .has_source = try c.function("source evidence availability", .{ .evidence = try e.context.schema(t.EvidenceList), .index = try e.context.schema(u64) }, try e.context.schema(bool), &.{}),
            .responder = if (controller) try protean.responders.defineControllerModelObserved(P, t.ControllerCarry, context, try context.literal(t.Failure, .invalid_response), false) else try protean.responders.defineModelObserved(P, context, try context.literal(t.Failure, .invalid_response), false),
            .inference = try t.controls.defineInference(context, try context.literal(t.Failure, .capacity)),
            .skill = try t.controls.defineSkill(P, context, try context.literal(t.Failure, .capacity)),
        };
        try program.defineEvidence();
        try program.defineLoop();
        const entry = try c.function("protean", .{ .input = try e.context.schema(if (controller) t.ControllerInput else t.Input) }, try e.context.schema(t.Output), .{ ops.bindings, ops.prepare, ops.work, ops.ask, ops.inspect, ops.workspace, ops.inbox, ops.model });
        const root = try c.body(entry);
        const input = try root.parameter("input");
        const result = if (controller) blk: {
            const private = try root.field(input, "private");
            const fresh = try root.caseOf(private, "initial");
            const resumed = try root.caseOf(private, "resume");
            const carry = resumed.payload();
            break :blk try root.match(private, .{
                .initial = try fresh.ret(try program.initialize(fresh.body(), fresh.payload())),
                .@"resume" = try resumed.ret(try resumed.body().call(loop, .{ .bindings = try resumed.body().field(carry, "bindings"), .state = try resumed.body().field(carry, "state") })),
            });
        } else try program.initialize(root, input);
        try c.define(entry, try root.ret(result));
        if (controller) {
            const imports = .{
                .{ t.bindings_identity, "task_view" },
                .{ t.prepare_identity, "context" },
                .{ t.work_identity, "snapshot" },
                .{ t.inspect_identity, "inspect" },
                .{ t.workspace_identity, "workspace" },
                .{ t.question_identity, "question" },
                .{ protean.inbox.semantic_identity, "inbox" },
            };
            for (context.builder.effects.items) |*effect| {
                inline for (imports) |binding| if (std.mem.eql(u8, effect.identity, binding[0])) {
                    effect.identity = @import("protean_contracts").controller.import_prefix ++ binding[1];
                };
                if (std.mem.startsWith(u8, effect.identity, @import("protean_contracts").controller.import_prefix)) effect.external = false;
            }
        }
        return c.module(entry, try e.context.schema(t.Failure));
    }
};

fn Program(comptime controller: bool) type {
    return struct {
        const Self = @This();
        e: Emit,
        ops: Ops(controller),
        loop: F(struct { bindings: t.PolicyView, state: t.State }, t.Output),
        report: *const @import("report.zig").Function,
        source_at: F(struct { evidence: t.EvidenceList, index: u64 }, ?t.SourceEvidenceReference),
        has_source: F(struct { evidence: t.EvidenceList, index: u64 }, bool),
        responder: *const protean.responders.ObservedFunction(P, false, if (controller) t.ControllerCarry else null),
        inference: *const t.controls.Function(t.controls.InferenceInput),
        skill: *const t.controls.Function(t.controls.SkillInput(P)),

        fn initialize(p: Self, root: anytype, input: V(t.Input)) !V(t.Output) {
            const e = p.e;
            const frozen = try root.perform(p.ops.bindings, try root.constant(void, {}));
            const task = try root.field(input, "task");
            const empty = try e.context.literal(t.State, .{
                .task = .{ .bytes = "" },
                .control = .{ .selection = .{ .profile_id = .{ .bytes = "" }, .profile_digest = @splat(0), .effective_effort = .medium, .control_revision = 0 }, .top_effort = .medium, .epoch = 0, .epoch_reason = .initial, .eviction_generation = 0, .skills = .{ .items = &.{} } },
                .replay = null,
                .results = .{ .items = &.{} },
                .messages = .{ .items = &.{} },
                .evidence = .{ .items = &.{} },
                .programs = .{ .items = &.{} },
                .receipts = .{ .items = &.{} },
                .model_calls = 0,
                .work_calls = 0,
            });
            const messages = try root.sequenceValue(try e.context.schema(P.Messages), &.{
                try e.message(root, .developer, try root.blobConcat(try e.context.schema(P.MessageText), try e.context.literal(P.MessageText, .{ .bytes = @embedFile("instructions.txt") ++ "\n" }), try root.field(frozen, "instructions"), try e.failure())),
                try e.message(root, .user, try e.widen(root, P.MessageText, task)),
                try e.message(root, .developer, try root.field(frozen, "status")),
            });
            const initial = try root.update(empty, .{ .task = task, .control = try root.field(frozen, "initial"), .messages = messages });
            const policy = try root.product(try e.context.schema(t.PolicyView), .{ .profiles = try root.field(frozen, "profiles"), .catalog = try root.field(frozen, "catalog") });
            return root.call(p.loop, .{ .bindings = policy, .state = initial });
        }

        fn defineEvidence(p: Self) !void {
            const e = p.e;
            const b = try e.author.body(p.source_at);
            const selected = try b.sequenceGet(try b.parameter("evidence"), try b.parameter("index"));
            const present = try b.caseOf(selected, "some");
            const absent = try b.caseOf(selected, "none");
            const item = present.payload();
            const source = try present.body().caseOf(item, "source");
            const workspace = try present.body().caseOf(item, "workspace");
            const projection = try present.body().match(item, .{ .source = try source.ret(try source.body().variant(try e.context.schema(?t.SourceEvidenceReference), "some", source.payload())), .workspace = try workspace.ret(try e.context.literal(?t.SourceEvidenceReference, null)) });
            try e.author.define(p.source_at, try b.ret(try b.match(selected, .{ .some = try present.ret(projection), .none = try absent.ret(try e.context.literal(?t.SourceEvidenceReference, null)) })));

            const any = try e.author.body(p.has_source);
            const evidence = try any.parameter("evidence");
            const index = try any.parameter("index");
            const scan = try any.branch();
            const end = try any.branch();
            const candidate = try scan.call(p.source_at, .{ .evidence = evidence, .index = index });
            const found = try scan.caseOf(candidate, "some");
            const skipped = try scan.caseOf(candidate, "none");
            const next = try skipped.body().checkedAdd(index, try skipped.body().constant(u64, 1), try e.failure());
            const result = try scan.match(candidate, .{ .some = try found.ret(try found.body().constant(bool, true)), .none = try skipped.ret(try skipped.body().call(p.has_source, .{ .evidence = evidence, .index = next })) });
            try e.author.define(p.has_source, try any.ret(try any.conditional(try any.less(index, try any.sequenceLength(evidence)), try scan.ret(result), try end.ret(try end.constant(bool, false)))));
        }

        fn offers(p: Self, b: anytype, state: anytype) !V([P.declaration_count]bool) {
            const evidence = try b.field(state, "evidence");
            var offered: [P.declaration_count]V(bool) = @splat(try b.constant(bool, true));
            offered[t.ordinal("report")] = try b.less(try b.constant(u64, 0), try b.sequenceLength(evidence));
            offered[t.ordinal("inspect")] = try b.call(p.has_source, .{ .evidence = evidence, .index = try b.constant(u64, 0) });
            return b.sequenceValue(try p.e.context.schema([P.declaration_count]bool), &offered);
        }
        fn stopped(p: Self, b: anytype, state: anytype, reason: []const u8) !V(t.Output) {
            return p.e.finish(b, state, .capacity, try p.e.context.literal(t.Summary, .{ .bytes = reason }));
        }
        fn defineLoop(p: Self) !void {
            const e = p.e;
            const b = try e.author.body(p.loop);
            const bindings = try b.parameter("bindings");
            const state = try b.parameter("state");
            const active = b;
            const preparation = try active.perform(p.ops.prepare, try active.product(try e.context.schema(t.Preparation), .{ .state = state, .offered = try p.offers(active, state), .control = try e.context.literal(?t.ControlSubject, null), .retained_calls = try e.context.literal(t.model.RetainedCalls, retained_calls) }));
            const ready = try active.caseOf(preparation, "ready");
            const rejected = try active.caseOf(preparation, "rejected");
            const interaction = ready.body();
            const request = try interaction.field(ready.payload(), "request");
            const counted = try interaction.update(state, .{ .model_calls = try interaction.checkedAdd(try interaction.field(state, "model_calls"), try interaction.constant(u64, 1), try e.failure()), .messages = try e.context.literal(P.Messages, .{ .items = &.{} }), .results = try e.context.literal(t.PendingResults, .{ .items = &.{} }) });
            const observation = if (controller)
                try interaction.call(p.responder, .{ .request = request, .offered = try interaction.field(request, "offered"), .carry = try interaction.product(try e.context.schema(t.ControllerCarry), .{ .bindings = bindings, .state = try interaction.update(counted, .{ .messages = try interaction.field(state, "messages"), .results = try interaction.field(state, "results") }) }) })
            else
                try interaction.call(p.responder, .{ .request = request, .offered = try interaction.field(request, "offered") });
            const normalized = try interaction.field(observation, "normalized");
            const diagnostic = if (controller) try interaction.field(observation, "diagnostic") else {};
            const rejected_control = if (controller) try interaction.caseOf(diagnostic, "some") else {};
            const unchanged = if (controller) try interaction.caseOf(diagnostic, "none") else {};
            const work = if (controller) unchanged.body() else interaction;
            const interpretation = try work.field(observation, "interpretation");
            const accepted = try work.caseOf(interpretation, "accepted");
            const refused = try work.caseOf(interpretation, "rejected");
            const chosen = accepted.body();
            const next = try chosen.update(counted, .{
                .replay = try chosen.field(normalized, "replay"),
                .results = try e.context.literal(@FieldType(t.State, "results"), .{ .items = &.{} }),
                .messages = try e.context.literal(P.Messages, .{ .items = &.{} }),
            });
            const output = try chosen.variantPayload(try chosen.field(normalized, "result"), "output", try e.failure());
            const call_id = try callId(e, chosen, try chosen.field(output, "items"));
            const action = accepted.payload();
            const Cases = comptime blk: {
                const names = @typeInfo(t.Action).@"union".field_names;
                var types: [names.len]type = undefined;
                for (names, 0..) |name, i| types[i] = @TypeOf(try (try chosen.caseOf(action, name)).ret(@as(V(t.Output), undefined)));
                break :blk native.Fields(names, &types);
            };
            var cases: Cases = undefined;
            inline for (@typeInfo(t.Action).@"union".field_names, 0..) |name, index| {
                const selected = try chosen.caseOf(action, name);
                @field(cases, name) = try selected.ret(try p.dispatchAction(selected.body(), bindings, next, call_id, selected.payload(), index));
            }
            const refusal = refused.body();
            const failed_result = try refusal.field(normalized, "result");
            const FailureCases = comptime blk: {
                const names = @typeInfo(P.Result).@"union".field_names;
                var types: [names.len]type = undefined;
                for (names, 0..) |name, i| types[i] = @TypeOf(try (try refusal.caseOf(failed_result, name)).ret(@as(V(t.Output), undefined)));
                break :blk native.Fields(names, &types);
            };
            var failure_cases: FailureCases = undefined;
            inline for (@typeInfo(P.Result).@"union".field_names) |name| {
                const selected = try refusal.caseOf(failed_result, name);
                const text = if (comptime std.mem.eql(u8, name, "refusal")) try e.widen(selected.body(), t.Summary, selected.payload()) else try e.context.literal(t.Summary, .{ .bytes = "The response did not contain one admissible action with complete replay." });
                @field(failure_cases, name) = try selected.ret(try e.finish(selected.body(), counted, if (comptime std.mem.eql(u8, name, "refusal")) .refusal else .no_result, text));
            }
            const unavailable = try refusal.match(failed_result, failure_cases);
            const ordinary = try work.match(interpretation, .{ .accepted = try accepted.ret(try chosen.match(action, cases)), .rejected = try refused.ret(unavailable) });
            const result = if (controller) blk: {
                const r = rejected_control.body();
                const continued = try r.update(counted, .{ .replay = try r.field(normalized, "replay") });
                const raw = try r.variantPayload(try r.field(normalized, "result"), "output", try e.failure());
                const failed_call = try callId(e, r, try r.field(raw, "items"));
                const diagnostic_text = try e.widen(r, t.Summary, try r.field(rejected_control.payload(), "observation"));
                const response = try r.variant(try e.context.schema(t.ResultValue), "inline_text", diagnostic_text);
                break :blk try interaction.match(diagnostic, .{ .some = try rejected_control.ret(try p.toolResult(r, bindings, continued, failed_call, response)), .none = try unchanged.ret(ordinary) });
            } else ordinary;
            const prepared = try active.match(preparation, .{ .ready = try ready.ret(result), .rejected = try rejected.ret(try p.stopped(rejected.body(), state, "The next context cannot be prepared within the admitted policy and capacity.")) });
            try e.author.define(p.loop, try b.ret(prepared));
        }
        fn resumeTask(p: Self, b: anytype, bindings: anytype, state: anytype) !V(t.Output) {
            const e = p.e;
            const poll = b;
            const raw = try poll.perform(p.ops.inbox, try poll.constant(void, {}));
            const inbox = raw;
            const empty = try poll.caseOf(inbox, "empty");
            const message = try poll.caseOf(inbox, "message");
            const arrived = message.body();
            const text = try arrived.field(try arrived.field(message.payload(), "value"), "message");
            const updated = try arrived.update(state, .{
                .messages = try arrived.sequenceValue(try e.context.schema(P.Messages), &.{try e.message(arrived, .user, try e.widen(arrived, P.MessageText, text))}),
            });
            const successor = try poll.match(inbox, .{ .empty = try empty.ret(state), .message = try message.ret(updated) });
            return poll.call(p.loop, .{ .bindings = bindings, .state = successor });
        }
        fn toolResult(p: Self, b: anytype, bindings: anytype, state: anytype, call_id: anytype, text: anytype) !V(t.Output) {
            const e = p.e;
            const result = try b.product(try e.context.schema(t.PendingResult), .{ .call_id = call_id, .output = text });
            const successor = try b.update(state, .{
                .results = try b.sequenceValue(try e.context.schema(@FieldType(t.State, "results")), &.{result}),
                .work_calls = try b.checkedAdd(try b.field(state, "work_calls"), try b.constant(u64, 1), try e.failure()),
            });
            return p.resumeTask(b, bindings, successor);
        }
        fn workResult(p: Self, b: anytype, bindings: anytype, state: anytype, call_id: anytype, payload: anytype, comptime index: usize) !V(t.Output) {
            const e = p.e;
            const context = try b.variantPayload(try b.field(state, "replay"), "some", try e.failure());
            const request = try b.product(try e.context.schema(t.WorkRequest), .{ .context = context, .call_id = call_id, .action = try b.variant(try e.context.schema(@FieldType(t.WorkRequest, "action")), if (index == 0) "list" else if (index == 1) "read" else "inspect", payload) });
            const reply = try b.perform(if (index == 7) p.ops.inspect else p.ops.work, request);
            const reference = try b.field(reply, "artifact");
            const evidence = try b.field(reply, "evidence");
            const some = try b.caseOf(evidence, "some");
            const none = try b.caseOf(evidence, "none");
            const updated = try b.match(evidence, .{ .some = try some.ret(try some.body().update(state, .{ .evidence = try some.body().append(try some.body().field(state, "evidence"), try some.body().variant(try e.context.schema(t.EvidenceReference), "source", some.payload()), .{}) })), .none = try none.ret(state) });
            return p.toolResult(b, bindings, updated, call_id, try b.variant(try e.context.schema(t.ResultValue), "work", reference));
        }
        fn dispatchAction(p: Self, b: anytype, bindings: anytype, state: anytype, call_id: anytype, value: anytype, comptime index: usize) !V(t.Output) {
            const e = p.e;
            switch (index) {
                0, 1 => return p.workResult(b, bindings, state, call_id, value, index),
                7 => {
                    const selected = try b.call(p.source_at, .{ .evidence = try b.field(state, "evidence"), .index = try b.field(value, "evidence_index") });
                    const source = try b.caseOf(selected, "some");
                    const unavailable = try b.caseOf(selected, "none");
                    const payload = try source.body().product(try e.context.schema(@FieldType(@FieldType(t.WorkRequest, "action"), "inspect")), .{ .evidence_index = try source.body().field(value, "evidence_index"), .evidence = source.payload() });
                    const rejected = try unavailable.body().variant(try e.context.schema(t.ResultValue), "inline_text", try e.context.literal(t.Summary, .{ .bytes = "Inspection requires an acquired source-file evidence index." }));
                    return b.match(selected, .{ .some = try source.ret(try p.workResult(source.body(), bindings, state, call_id, payload, 7)), .none = try unavailable.ret(try p.toolResult(unavailable.body(), bindings, state, call_id, rejected)) });
                },
                2 => {
                    const question = try b.product(try e.context.schema(t.Question), .{ .prompt = try b.field(value, "question") });
                    const answer = try b.perform(p.ops.ask, question);
                    return p.toolResult(b, bindings, state, call_id, try b.variant(try e.context.schema(t.ResultValue), "inline_text", try b.field(answer, "message")));
                },
                3 => {
                    const checked = try b.call(p.report, .{ .report = value, .evidence_count = try b.sequenceLength(try b.field(state, "evidence")) });
                    const rejected = try b.caseOf(checked, "some");
                    const accepted = try b.caseOf(checked, "none");
                    const failed = rejected.body();
                    const reply = try failed.product(try e.context.schema(t.PendingResult), .{ .call_id = call_id, .output = try failed.variant(try e.context.schema(t.ResultValue), "report_rejection", rejected.payload()) });
                    const corrected = try failed.update(state, .{ .results = try failed.sequenceValue(try e.context.schema(t.PendingResults), &.{reply}) });
                    return b.match(checked, .{ .some = try rejected.ret(try p.resumeTask(failed, bindings, corrected)), .none = try accepted.ret(try e.finish(accepted.body(), state, .report, value)) });
                },
                4 => return e.finish(b, state, .no_result, try e.widen(b, t.Summary, try b.field(value, "reason"))),
                5, 6 => return p.control(b, bindings, state, call_id, value, index == 5),
                t.ordinal("program"), t.ordinal("work"), t.ordinal("context"), t.ordinal("placement") => {
                    const command = comptime if (index == t.ordinal("program")) "program" else if (index == t.ordinal("work")) "work" else if (index == t.ordinal("placement")) "placement" else "context";
                    const request = try b.product(try e.context.schema(t.WorkspaceRequest), .{ .context = try b.variantPayload(try b.field(state, "replay"), "some", try e.failure()), .call_id = call_id, .action = try b.variant(try e.context.schema(@FieldType(t.WorkspaceRequest, "action")), command, try b.field(value, "command")) });
                    const reply = try b.perform(p.ops.workspace, request);
                    const selected = try b.field(reply, "selected_view");
                    const some = try b.caseOf(selected, "some");
                    const none = try b.caseOf(selected, "none");
                    const selecting = some.body();
                    const old_control = try selecting.field(state, "control");
                    const selected_control = try selecting.update(old_control, .{
                        .epoch = try selecting.checkedAdd(try selecting.field(old_control, "epoch"), try selecting.constant(u64, 1), try e.failure()),
                        .epoch_reason = try e.context.literal(t.model.EpochReason, .view_change),
                    });
                    var updated = try b.match(selected, .{
                        .some = try some.ret(try selecting.update(state, .{ .selected_view = selected, .selected_view_at = try selecting.field(try selecting.variantPayload(try selecting.field(state, "replay"), "some", try e.failure()), "watermark"), .control = selected_control })),
                        .none = try none.ret(state),
                    });
                    const evidence = try b.field(reply, "evidence");
                    const has_evidence = try b.caseOf(evidence, "some");
                    const no_evidence = try b.caseOf(evidence, "none");
                    const evidence_index = try b.match(evidence, .{ .some = try has_evidence.ret(try has_evidence.body().variant(try e.context.schema(?u64), "some", try b.sequenceLength(try b.field(state, "evidence")))), .none = try no_evidence.ret(try e.context.literal(?u64, null)) });
                    inline for (.{ "evidence", "program" }) |field| {
                        const optional = try b.field(reply, field);
                        const present = try b.caseOf(optional, "some");
                        const absent = try b.caseOf(optional, "none");
                        const target = comptime if (std.mem.eql(u8, field, "program")) "programs" else "evidence";
                        const item = if (comptime std.mem.eql(u8, field, "program")) present.payload() else try present.body().variant(try e.context.schema(t.EvidenceReference), "workspace", present.payload());
                        const appended = try present.body().append(try present.body().field(updated, target), item, .{});
                        const changed = if (comptime std.mem.eql(u8, field, "program")) try present.body().update(updated, .{ .programs = appended }) else try present.body().update(updated, .{ .evidence = appended });
                        updated = try b.match(optional, .{ .some = try present.ret(changed), .none = try absent.ret(updated) });
                    }
                    const result = try b.product(try e.context.schema(t.WorkspaceResult), .{ .reply = reply, .evidence_index = evidence_index });
                    return p.toolResult(b, bindings, updated, call_id, try b.variant(try e.context.schema(t.ResultValue), "workspace", result));
                },
                else => unreachable,
            }
        }
        fn control(p: Self, b: anytype, bindings: anytype, state: anytype, call_id: anytype, command: anytype, comptime inference: bool) !V(t.Output) {
            const e = p.e;
            const Input = if (inference) t.controls.InferenceInput else t.controls.SkillInput(P);
            const input = try b.product(try e.context.schema(Input), if (inference) .{
                .state = try b.field(state, "control"),
                .profiles = try b.field(bindings, "profiles"),
                .command = command,
            } else .{
                .state = try b.field(state, "control"),
                .catalog = try b.field(bindings, "catalog"),
                .command = command,
                .watermark = try b.field(try b.variantPayload(try b.field(state, "replay"), "some", try e.failure()), "watermark"),
            });
            const proposal = try b.call(if (inference) p.inference else p.skill, .{ .input = input });
            const subject = try b.product(try e.context.schema(t.ControlSubject), .{ .call_id = call_id, .reason = try b.field(command, "reason"), .proposal = proposal });
            const preparation = try b.perform(p.ops.prepare, try b.product(try e.context.schema(t.Preparation), .{ .state = state, .offered = try p.offers(b, state), .control = try b.variant(try e.context.schema(?t.ControlSubject), "some", subject), .retained_calls = try e.context.literal(t.model.RetainedCalls, retained_calls) }));
            const ready = try b.caseOf(preparation, "ready");
            const rejected = try b.caseOf(preparation, "rejected");
            const accepted = ready.body();
            const receipt = try accepted.variantPayload(try accepted.field(ready.payload(), "receipt"), "some", try e.failure());
            const committed = try accepted.update(state, .{
                .control = try accepted.field(proposal, "state"),
                .results = try accepted.field(ready.payload(), "results"),
                .receipts = try accepted.append(try accepted.field(state, "receipts"), receipt, .{}),
            });
            const failed = rejected.body();
            var reason = try e.context.literal(t.Summary, .{ .bytes = "Control preparation rejected. Configuration and control revision are unchanged; no inference was performed by the control." });
            inline for ([_]t.controls.Rejection{ .capacity, .unknown_profile, .unknown_skill, .unsupported_effort, .invalid_operation }) |kind| {
                const text = "{\"disposition\":\"rejected\",\"reason\":\"" ++ @tagName(kind) ++ "\",\"configuration_changed\":false,\"inference_performed\":false}";
                reason = try failed.select(try failed.equal(try failed.enumTag(rejected.payload()), try failed.enumTag(try e.context.literal(t.controls.Rejection, kind))), try e.context.literal(t.Summary, .{ .bytes = text }), reason);
            }
            const reply = try failed.product(try e.context.schema(t.PendingResult), .{ .call_id = call_id, .output = try failed.variant(try e.context.schema(t.ResultValue), "inline_text", reason) });
            const unchanged = try failed.update(state, .{ .results = try failed.sequenceValue(try e.context.schema(@FieldType(t.State, "results")), &.{reply}) });
            return b.match(preparation, .{ .ready = try ready.ret(try p.resumeTask(accepted, bindings, committed)), .rejected = try rejected.ret(try p.resumeTask(failed, bindings, unchanged)) });
        }
    };
}
fn callId(e: Emit, parent: anytype, items: anytype) !V(P.CallId) {
    const c = e.author;
    const scan = try c.function("accepted model call identity", .{ .items = try e.context.schema(P.OutputItems), .index = try c.schema(u64) }, try e.context.schema(P.CallId), &.{});
    const b = try c.body(scan);
    const list = try b.parameter("items");
    const index = try b.parameter("index");
    const raw = try b.variantPayload(try b.sequenceGet(list, index), "some", try e.failure());
    const item = raw;
    const names = .{ "function_call", "message", "reasoning" };
    const Cases = comptime blk: {
        var types: [names.len]type = undefined;
        for (names, 0..) |name, i| types[i] = @TypeOf(try (try b.caseOf(item, name)).ret(@as(V(P.CallId), undefined)));
        break :blk native.Fields(&names, &types);
    };
    var cases: Cases = undefined;
    inline for (.{ "function_call", "message", "reasoning" }, 0..) |name, i| {
        const branch = try b.caseOf(item, name);
        const body = branch.body();
        @field(cases, name) = try branch.ret(if (i == 0) try body.field(branch.payload(), "call_id") else try body.call(scan, .{ .items = list, .index = try body.checkedAdd(index, try body.constant(u64, 1), try e.failure()) }));
    }
    try c.define(scan, try b.ret(try b.match(item, cases)));
    return parent.call(scan, .{ .items = items, .index = try parent.constant(u64, 0) });
}
