//! Pure context construction with captured native allowance observations.
//! Selection stays authored; native dispatch remains the authority for work.
const std = @import("std");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const t = @import("application_types");
const P = t.P;
const work = @import("work.zig");
const tool_work = @import("tool_work.zig");
const tool_resources = @import("tool_resources.zig");
const A = native.adaptive_responses.Admission(P);
const Adapter = native.adaptive_responses.Adapter(P);
const Product = t.PreparationProduct;

fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn digest(bytes: []const u8) [32]u8 {
    var value: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &value, .{});
    return value;
}
fn encodedEqual(a: std.mem.Allocator, comptime T: type, left: T, right: T) !bool {
    return equal(try contracts.encodeOwned(T, a, left), try contracts.encodeOwned(T, a, right));
}
fn profile(policy: P.AdaptivePolicy, id: []const u8) !A.Profile {
    for (policy.profiles.items) |entry| if (equal(id, entry.id.bytes)) return entry;
    return error.UnknownInferenceProfile;
}
pub fn instructions(a: std.mem.Allocator, policy: P.AdaptivePolicy, catalog: P.AdaptiveCatalog) !P.MessageText {
    // Metadata never includes the instruction bodies or resource filesystem paths.
    const Profile = struct { id: contracts.Text(64), model: contracts.Text(128), efforts: @FieldType(A.Profile, "efforts") };
    const Skill = struct { id: contracts.Text(64), version: contracts.Text(64), description: contracts.Text(256) };
    const profiles = try a.alloc(Profile, policy.profiles.items.len);
    for (profiles, policy.profiles.items) |*out, entry| out.* = .{ .id = entry.id, .model = entry.model, .efforts = entry.efforts };
    const skills = try a.alloc(Skill, catalog.skills.items.len);
    for (skills, catalog.skills.items) |*out, entry| out.* = .{ .id = entry.id, .version = entry.version, .description = entry.description };
    const Catalog = struct { profiles: contracts.Vector(Profile, 8), skills: contracts.Vector(Skill, 32) };
    const metadata = try native.json.canonical(a, try native.values.toJson(Catalog, a, .{ .profiles = .{ .items = profiles }, .skills = .{ .items = skills } }));
    const text = try std.fmt.allocPrint(a, "{s}\nApproved catalog:\n{s}", .{ @embedFile("instructions.txt"), metadata });
    if (text.len > P.MessageText.max_length.?) return error.Capacity;
    return .{ .bytes = text };
}

pub fn declaration() native.Declaration {
    return .{ .identity = t.prepare_identity, .resource_role = "context", .kind = .leaf, .background = true, .payload_schema = struct {
        fn schema(a: std.mem.Allocator) ![]u8 {
            return native.values.schemaBytes(t.Preparation, a);
        }
    }.schema, .resume_schema = struct {
        fn schema(a: std.mem.Allocator) ![]u8 {
            return native.values.schemaBytes(t.PreparationResult, a);
        }
    }.schema, .capture = .{ .prepare = prepare, .acquire = acquire, .interpret = interpret } };
}

fn receiptText(a: std.mem.Allocator, receipt: t.ControlReceipt, control: t.controls.State) !P.ResultText {
    var value = try native.values.toJson(t.ControlReceipt, a, receipt);
    // Model-facing revision arguments are exact JSON integers, independent of
    // the machine protocol's decimal-string u64 mapping.
    inline for (.{ "previous_revision", "next_revision", "context_epoch", "eviction_generation" }) |name| try native.json.put(a, &value, name, try native.json.number(a, @field(receipt, name)));
    try native.json.put(a, &value, "takes_effect", native.json.string("next inference; no provider request has been executed by this control"));
    try native.json.put(a, &value, "skills", try native.values.toJson(@FieldType(t.controls.State, "skills"), a, control.skills));
    return .{ .bytes = try native.json.canonicalBounded(a, value, P.ResultText.max_length.?) };
}

fn controlSource(ctx: native.registry.ProjectionContext, state: t.State, subject: t.ControlSubject, policy: P.AdaptivePolicy) !contracts.Decoded(P.AdaptiveContext) {
    const ref = state.replay orelse return error.InvalidContext;
    var prior = try Adapter.Context.open(ctx, ref, policy.audience.bytes);
    errdefer prior.deinit();
    if (!try encodedEqual(ctx.allocator, t.model.AdaptiveSelection, state.control.selection, prior.value.selection) or
        state.control.epoch != prior.value.plan.epoch or state.control.eviction_generation != prior.value.plan.eviction_generation or
        !try encodedEqual(ctx.allocator, @FieldType(t.controls.State, "skills"), state.control.skills, prior.value.plan.skills)) return error.InvalidContext;
    const prepared_bytes = try ctx.object(.{ .digest = prior.value.source_request.digest, .bytes = prior.value.source_request.bytes }, 2 * 1024 * 1024);
    var prepared = try contracts.decodeOwned(Adapter.Prepared, ctx.allocator, prepared_bytes);
    defer prepared.deinit();
    const capture = try ctx.object(.{ .digest = prior.value.source_capture.digest, .bytes = prior.value.source_capture.bytes }, 4 * 1024 * 1024);
    var raw = try contracts.decodeOwned(native.responses.Raw, ctx.allocator, capture);
    defer raw.deinit();
    const response = (try native.json.parse(ctx.allocator, raw.value.body.bytes, .{ .bytes = P.representation.provider_response_bytes })).value;
    const output = native.json.get(response, "output") orelse return error.InvalidCapture;
    const normalized = try native.responses.Adapter(P).normalize(ctx.allocator, prepared.value.request.invocation, output);
    if (normalized != .output) return error.InvalidCapture;
    var found = false;
    for (normalized.output.items.items) |item| if (item == .function_call and equal(item.function_call.call_id.bytes, subject.call_id.bytes)) {
        const call = item.function_call;
        if (found or call.tool_ordinal_claim >= P.declaration_count or !prepared.value.request.offered[call.tool_ordinal_claim] or call.decoded_action != .decoded) return error.InvalidCapture;
        const action = call.decoded_action.decoded;
        const reason = switch (action) {
            .inference_set => |value| value.reason,
            .skill_set => |value| value.reason,
            else => return error.InvalidCapture,
        };
        if (!equal(reason.bytes, subject.reason.bytes)) return error.InvalidCapture;
        const expected = switch (action) {
            .inference_set => |command| command.expected_revision,
            .skill_set => |command| command.expected_revision,
            else => return error.InvalidCapture,
        };
        if (subject.proposal.disposition != .rejected and expected != state.control.selection.control_revision) return error.InvalidCapture;
        if (subject.proposal.disposition == .proposed and action == .inference_set and
            (!equal(subject.proposal.state.selection.profile_id.bytes, action.inference_set.profile_id.bytes) or subject.proposal.state.selection.effective_effort != action.inference_set.effort)) return error.InvalidCapture;
        found = true;
    };
    if (!found) return error.InvalidCapture;
    return prior;
}

fn evaluate(ctx: native.registry.ProjectionContext, input: t.Preparation) !Product {
    const a = ctx.allocator;
    const policy = try A.policy(a, ctx.profile);
    var catalog = try A.catalog(ctx, policy);
    defer catalog.deinit();
    var control = input.state.control;
    var receipt: ?t.ControlReceipt = null;
    var text: ?P.ResultText = null;
    const pending = input.state.results;
    const resolved = try a.alloc(P.ToolResult, pending.items.len);
    for (resolved, pending.items) |*out, item| {
        const content: []const u8 = switch (item.output) {
            .inline_text => |value| value.bytes,
            .work => |ref| blk: {
                var record = try work.open(ctx, ref);
                defer record.deinit();
                if (!equal(record.value.call_id.bytes, item.call_id.bytes)) return error.InvalidWorkArtifact;
                break :blk try a.dupe(u8, record.value.model_text.bytes);
            },
            .tool => |ref| blk: {
                var record = try tool_work.open(ctx, ref);
                defer record.deinit();
                if (!equal(record.value.call_id.bytes, item.call_id.bytes)) return error.InvalidToolArtifact;
                break :blk try a.dupe(u8, record.value.model_text.bytes);
            },
            .control => |ref| blk: {
                const bytes = try ctx.object(.{ .digest = ref.digest, .bytes = ref.bytes }, 128 * 1024);
                var record = try contracts.decodeOwned(t.ReceiptArtifact, a, bytes);
                defer record.deinit();
                if (!equal(&record.value.receipt.task, &ctx.task) or !equal(record.value.receipt.call_id.bytes, item.call_id.bytes)) return error.InvalidContext;
                break :blk try a.dupe(u8, record.value.model_text.bytes);
            },
        };
        out.* = .{ .call_id = item.call_id, .output = .{ .bytes = content } };
    }
    var results: @FieldType(P.AdaptiveRequest, "results") = .{ .items = resolved };
    if (input.control) |subject| {
        var prior = try controlSource(ctx, input.state, subject, policy);
        defer prior.deinit();
        if (input.state.receipts.items.len == 16) return error.Capacity;
        if (subject.proposal.disposition == .proposed) {
            if (subject.proposal.rejection != .none) return error.InvalidContext;
            if (subject.proposal.state.selection.control_revision != try std.math.add(u64, control.selection.control_revision, 1)) return error.InvalidContext;
            control = subject.proposal.state;
        } else if (!try encodedEqual(a, t.controls.State, control, subject.proposal.state)) return error.InvalidContext;
        receipt = .{
            .task = ctx.task,
            .source = prior.value.source_capture,
            .call_id = subject.call_id,
            .previous_revision = input.state.control.selection.control_revision,
            .next_revision = control.selection.control_revision,
            .disposition = switch (subject.proposal.disposition) {
                .proposed => .admitted,
                .unchanged => .unchanged,
                .rejected => .rejected,
            },
            .rejection = subject.proposal.rejection,
            .previous_profile = input.state.control.selection.profile_id,
            .next_profile = control.selection.profile_id,
            .previous_model = (try profile(policy, input.state.control.selection.profile_id.bytes)).model,
            .next_model = (try profile(policy, control.selection.profile_id.bytes)).model,
            .previous_effort = input.state.control.selection.effective_effort,
            .next_effort = control.selection.effective_effort,
            .context_epoch = control.epoch,
            .eviction_generation = control.eviction_generation,
        };
        text = try receiptText(a, receipt.?, control);
        const items = try a.alloc(P.ToolResult, 1);
        items[0] = .{ .call_id = subject.call_id, .output = text.? };
        results = .{ .items = items };
    }
    const selected = try profile(policy, control.selection.profile_id.bytes);
    var materialized = policy.core_tools;
    var offered = policy.core_tools;
    for (control.skills.items) |loaded| for (catalog.value.skills.items) |skill| if (equal(loaded.skill_id.bytes, skill.id.bytes)) {
        for (skill.tools, 0..) |enabled, ordinal| {
            materialized[ordinal] = materialized[ordinal] or enabled;
            offered[ordinal] = offered[ordinal] or (enabled and loaded.active);
        }
    };
    for (&offered, input.offered, policy.permitted_tools) |*allowed, requested, permitted| allowed.* = allowed.* and requested and permitted;
    var declarations: std.ArrayList(P.ToolDeclaration) = .empty;
    for (materialized, P.allDeclarations().items) |defined, item| if (defined) try declarations.append(a, item);
    var messages = input.state.messages;
    if (input.state.replay) |prior| if (prior.eviction_generation != control.eviction_generation and input.state.programs.items.len != 0) {
        if (messages.items.len == t.P.Messages.max_length) return error.Capacity;
        var retained: native.json.Value = .{ .array = .init(a) };
        for (input.state.programs.items) |ref| try retained.array.append(native.json.string(try tool_resources.referenceText(a, ref)));
        const text_value = try std.fmt.allocPrint(a, "Retained generated tool references after instruction eviction: {s}. These references carry no authority; tool_run still checks the frozen policy and input. Acquired evidence indexes remain stable.", .{try native.json.canonical(a, retained)});
        const items = try a.alloc(t.P.Message, messages.items.len + 1);
        @memcpy(items[0..messages.items.len], messages.items);
        items[messages.items.len] = .{ .role = .developer, .content = .{ .bytes = text_value } };
        messages = .{ .items = items };
    };
    const request: P.AdaptiveRequest = .{
        .policy = digest(ctx.profile),
        .selection = control.selection,
        .materialized = materialized,
        .offered = offered,
        .results = results,
        .plan = .{ .epoch = control.epoch, .reason = control.epoch_reason, .watermark = if (input.state.replay) |ref| ref.watermark else 0, .eviction_generation = control.eviction_generation, .prior = input.state.replay, .catalog = policy.catalog, .skills = control.skills },
        .invocation = .{
            .protocol = .{ .bytes = t.model.protocol_identity },
            .model = selected.model,
            .parameters = .{ .max_output_tokens = selected.max_output_tokens, .temperature = null, .reasoning = .{ .effort = control.top_effort, .summary = null } },
            .messages = messages,
            .tools = .{ .items = declarations.items },
            .selection = .{ .minimum_calls = 1, .maximum_calls = 1, .parallel_calls = false },
            .response_policy = .{ .store = false, .stream = false, .background = false, .truncation = .disabled },
            .normalization_limits = P.normalizationLimits(),
            .maximum_provider_response_bytes = selected.response_bytes,
        },
    };
    // Horos retains the computation and task facts. Continue its immutable
    // transcript; only the projection owner changes provider-visible material.
    _ = try Adapter.prepare(ctx, try contracts.encodeOwned(P.AdaptiveRequest, a, request));
    var receipt_object: ?contracts.Bytes(128 * 1024) = null;
    var receipt_ref: ?t.ReceiptReference = null;
    var next_results = pending;
    if (receipt) |value| {
        const bytes = try contracts.encodeOwned(t.ReceiptArtifact, a, .{ .receipt = value, .model_text = text.? });
        receipt_object = .{ .bytes = bytes };
        const ref = work.reference(bytes);
        receipt_ref = .{ .object = ref, .previous_revision = value.previous_revision, .next_revision = value.next_revision, .disposition = value.disposition, .rejection = value.rejection, .next_profile = value.next_profile, .next_effort = value.next_effort, .context_epoch = value.context_epoch, .eviction_generation = value.eviction_generation };
        const items = try a.alloc(t.PendingResult, 1);
        items[0] = .{ .call_id = value.call_id, .output = .{ .control = ref } };
        next_results = .{ .items = items };
    }
    return .{ .result = .{ .ready = .{ .request = request, .receipt = receipt_ref, .results = next_results } }, .receipt = receipt_object };
}

fn prepare(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
    var input = try contracts.decodeOwned(t.Preparation, ctx.allocator, bytes);
    defer input.deinit();
    const product = evaluate(ctx, input.value) catch |err| switch (err) {
        error.Capacity => Product{ .result = .{ .rejected = .capacity }, .receipt = null },
        error.UnknownSkill, error.InvalidSkill => Product{ .result = .{ .rejected = .unknown_skill }, .receipt = null },
        error.UnknownInferenceProfile => Product{ .result = .{ .rejected = .unknown_profile }, .receipt = null },
        error.UnsupportedEffort => Product{ .result = .{ .rejected = .unsupported_effort }, .receipt = null },
        error.IncompatibleProfile => Product{ .result = .{ .rejected = .invalid_operation }, .receipt = null },
        else => return err,
    };
    return contracts.encodeOwned(Product, ctx.allocator, product);
}
fn acquire(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
    ctx.checkCancellation() catch |err| return .{ .definitely_not_sent = err };
    return .{ .captured = try contracts.encodeOwned(t.PreparationCapture, ctx.allocator, .{
        .prepared = digest(bytes),
        .build_exhausted = ctx.nextAttemptLimitExhausted(t.tool_build_identity),
        .run_exhausted = ctx.nextAttemptLimitExhausted(t.tool_run_identity),
    }) };
}
fn interpret(ctx: native.registry.ProjectionContext, request: []const u8, prepared: []const u8, captured: []const u8) !native.registry.Projection {
    var observation = try contracts.decodeOwned(t.PreparationCapture, ctx.allocator, captured);
    defer observation.deinit();
    if (!equal(&observation.value.prepared, &digest(prepared)) or !equal(try prepare(ctx, request), prepared)) return error.InvalidCapture;
    var product = try contracts.decodeOwned(Product, ctx.allocator, prepared);
    defer product.deinit();
    // Replay the original observation, never today's mutable attempt count.
    // Intersecting the prepared mask cannot introduce an ungranted operation.
    if (product.value.result == .ready) {
        const offered = &product.value.result.ready.request.offered;
        offered[t.ordinal("tool_build")] = offered[t.ordinal("tool_build")] and !observation.value.build_exhausted;
        offered[t.ordinal("tool_run")] = offered[t.ordinal("tool_run")] and !observation.value.run_exhausted;
    }
    const objects = try ctx.allocator.alloc([]const u8, @intFromBool(product.value.receipt != null));
    if (product.value.receipt) |receipt| objects[0] = try ctx.allocator.dupe(u8, receipt.bytes);
    return .{ .reply = try contracts.encodeOwned(t.PreparationResult, ctx.allocator, product.value.result), .objects = objects };
}
