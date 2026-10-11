//! Pure authored adaptive control. These computations propose ordinary values;
//! the application commits them only after context preparation succeeds.
const std = @import("std");
const horos = @import("horos");
const authoring = @import("authoring.zig");
const contracts = @import("protean_contracts");
const model = @import("model_invocation.zig");
const Effort = @import("model.zig").ReasoningEffort;
const a = horos.authoring;
const Id = horos.source.Id;
const V = *const a.Value;

pub const InferenceSet = struct {
    profile_id: contracts.Text(64),
    effort: Effort,
    expected_revision: u64,
    reason: contracts.Text(256),
};
pub const SkillSet = struct {
    operation: enum { load, deactivate, unload },
    skill_id: contracts.Text(64),
    version: contracts.Text(64),
    residency: enum { resident, transient, unchanged },
    expected_revision: u64,
    reason: contracts.Text(256),
};
pub const InferenceCapability = struct { id: contracts.Text(64), efforts: @FieldType(model.AdaptiveInferenceProfile, "efforts"), effort_update: bool };
pub const ProfileChoice = struct { profile: InferenceCapability, digest: [32]u8 };
pub fn profileChoice(profile: model.AdaptiveInferenceProfile, digest: [32]u8) ProfileChoice {
    return .{ .profile = .{ .id = profile.id, .efforts = profile.efforts, .effort_update = profile.effort_update }, .digest = digest };
}
pub const Skill = struct { id: contracts.Text(64), version: contracts.Text(64), instructions: model.ArtifactReference };
pub const Catalog = struct { skills: contracts.Vector(Skill, 32) };
pub const Profiles = contracts.Vector(ProfileChoice, 8);
pub const State = struct {
    selection: model.AdaptiveSelection,
    top_effort: Effort,
    epoch: u64,
    epoch_reason: model.EpochReason,
    eviction_generation: u64,
    skills: contracts.Vector(model.SkillMaterialization, 32),
};
pub const Rejection = enum { none, stale_revision, unknown_profile, unsupported_effort, unknown_skill, version_mismatch, invalid_operation, capacity };
pub const Proposal = struct {
    state: State,
    disposition: enum { proposed, unchanged, rejected },
    rejection: Rejection,
};
pub const InferenceInput = struct { state: State, profiles: Profiles, command: InferenceSet, maximum_revision: u64 };
pub fn SkillInput(comptime _: type) type {
    return struct { state: State, catalog: Catalog, command: SkillSet, watermark: u64, maximum_revision: u64 };
}

const Emit = struct {
    context: authoring.Context,
    typed: *a.Context,
    failure: Id,

    fn schema(e: Emit, comptime T: type) !*const a.Schema {
        return a.interop.schema(e.typed, try e.context.schema(T));
    }
    fn literal(e: Emit, body: *a.Body, comptime T: type, value: T) !V {
        return a.interop.adoptValue(body, try e.context.literal(T, value), try e.schema(T));
    }
    fn field(_: Emit, body: *a.Body, value: V, comptime T: type, comptime name: []const u8) !V {
        return body.field(value, std.fmt.comptimePrint("{d}", .{std.meta.fieldIndex(T, name).?}));
    }
    fn replace(e: Emit, body: *a.Body, comptime T: type, value: V, changes: anytype) !V {
        var fields: [@typeInfo(T).@"struct".field_names.len]a.Argument = undefined;
        inline for (@typeInfo(T).@"struct".field_names, 0..) |name, index| fields[index] = .{
            .name = std.fmt.comptimePrint("{d}", .{index}),
            .value = if (@hasField(@TypeOf(changes), name)) @field(changes, name) else try e.field(body, value, T, name),
        };
        return body.product(try e.schema(T), &fields);
    }
    fn outcome(e: Emit, body: *a.Body, state: V, disposition: @FieldType(Proposal, "disposition"), rejection: Rejection) !V {
        return body.product(try e.schema(Proposal), &.{
            .{ .name = "0", .value = state },
            .{ .name = "1", .value = try e.literal(body, @FieldType(Proposal, "disposition"), disposition) },
            .{ .name = "2", .value = try e.literal(body, Rejection, rejection) },
        });
    }
    fn increment(e: Emit, body: *a.Body, value: V) !V {
        const fault = try a.interop.literalFailure(e.typed, e.failure, try a.interop.schema(e.typed, e.context.builder.values.items[e.failure].schema));
        return body.checkedAdd(value, try body.constant(u64, 1), fault);
    }
    fn sameText(_: Emit, body: *a.Body, left: V, right: V) !V {
        return body.equal(try body.blobCompare(left, right), try body.constant(i8, 0));
    }
    fn either(_: Emit, body: *a.Body, left: V, right: V) !V {
        return body.select(left, try body.constant(bool, true), right);
    }
    fn both(_: Emit, body: *a.Body, left: V, right: V) !V {
        return body.select(left, right, try body.constant(bool, false));
    }
    fn append(e: Emit, body: *a.Body, vector: V, item: V) !V {
        const T = @FieldType(State, "skills");
        const raw = try e.context.builder.value(.{ .schema = try e.context.schema(T), .expression = .{ .primitive = .{
            .opcode = .sequence_append,
            .operands = &.{ try a.interop.valueId(body, vector), try a.interop.valueId(body, item) },
            .failures = &.{.{ .kind = .capacity_exceeded, .value = try e.context.builder.failureLiteral(e.failure) }},
        } } });
        return a.interop.adoptValue(body, raw, try e.schema(T));
    }
};

/// `(InferenceInput) -> Proposal`, with no environmental effects. Lookup and
/// effort admission execute inside the authored program over frozen metadata.
pub fn defineInference(c: authoring.Context, failure: Id) !Id {
    const b = c.builder;
    const cached = try b.specialization(Id, "agent.adaptive.inference-control/v1", .{try b.failureLiteral(failure)});
    if (cached.cached) |existing| return existing;
    const typed = try a.Context.init(b);
    const e: Emit = .{ .context = c, .typed = typed, .failure = failure };
    const lookup = try typed.function("adaptive profile lookup", &.{
        .{ .name = "input", .schema = try e.schema(InferenceInput) },
        .{ .name = "index", .schema = try typed.scalar(u64) },
    }, try e.schema(Proposal), &.{});
    const scan = try typed.body(lookup);
    const input = try scan.parameter("input");
    const index = try scan.parameter("index");
    const state = try e.field(scan, input, InferenceInput, "state");
    const command = try e.field(scan, input, InferenceInput, "command");
    const selection = try e.field(scan, state, State, "selection");
    const selected = try scan.sequenceGet(try e.field(scan, input, InferenceInput, "profiles"), index);
    const found = try scan.caseOf(selected, "some");
    const missing = try scan.caseOf(selected, "none");
    const current = found.body();
    const choice = found.payload();
    const profile = try e.field(current, choice, ProfileChoice, "profile");
    const match = try current.branch();
    const next = try current.branch();
    const effort = try e.field(match, command, InferenceSet, "effort");
    const supported = try supportsEffort(e, match, try e.field(match, profile, InferenceCapability, "efforts"), effort);
    const admitted = try match.branch();
    const unsupported = try match.branch();
    const same_profile = try e.sameText(admitted, try e.field(admitted, selection, model.AdaptiveSelection, "profile_id"), try e.field(admitted, command, InferenceSet, "profile_id"));
    const same_effort = try admitted.equal(try admitted.enumTag(try e.field(admitted, selection, model.AdaptiveSelection, "effective_effort")), try admitted.enumTag(effort));
    const unchanged = try admitted.branch();
    const changed = try admitted.branch();
    const revision = try e.field(changed, selection, model.AdaptiveSelection, "control_revision");
    const room = try changed.branch();
    const full = try changed.branch();
    const keeps_epoch = try room.select(same_profile, try e.field(room, profile, InferenceCapability, "effort_update"), try room.constant(bool, false));
    const old_epoch = try e.field(room, state, State, "epoch");
    const epoch = try room.select(keeps_epoch, old_epoch, try e.increment(room, old_epoch));
    const next_selection = try e.replace(room, model.AdaptiveSelection, selection, .{
        .profile_id = try e.field(room, command, InferenceSet, "profile_id"),
        .profile_digest = try e.field(room, choice, ProfileChoice, "digest"),
        .effective_effort = effort,
        .control_revision = try e.increment(room, revision),
    });
    const reason = try room.select(same_profile, try e.literal(room, model.EpochReason, .effort_change), try e.literal(room, model.EpochReason, .model_change));
    const successor = try e.replace(room, State, state, .{
        .selection = next_selection,
        .top_effort = try room.select(keeps_epoch, try e.field(room, state, State, "top_effort"), effort),
        .epoch = epoch,
        .epoch_reason = try room.select(keeps_epoch, try e.field(room, state, State, "epoch_reason"), reason),
    });
    const changed_result = try changed.conditional(try changed.less(revision, try e.field(changed, input, InferenceInput, "maximum_revision")), try room.ret(try e.outcome(room, successor, .proposed, .none)), try full.ret(try e.outcome(full, state, .rejected, .capacity)));
    const admitted_result = try admitted.conditional(try admitted.select(same_profile, same_effort, try admitted.constant(bool, false)), try unchanged.ret(try e.outcome(unchanged, state, .unchanged, .none)), try changed.ret(changed_result));
    const matched_result = try match.conditional(supported, try admitted.ret(admitted_result), try unsupported.ret(try e.outcome(unsupported, state, .rejected, .unsupported_effort)));
    const next_result = try next.call(lookup, &.{ .{ .name = "input", .value = input }, .{ .name = "index", .value = try e.increment(next, index) } });
    const found_result = try current.conditional(try e.sameText(current, try e.field(current, profile, InferenceCapability, "id"), try e.field(current, command, InferenceSet, "profile_id")), try match.ret(matched_result), try next.ret(next_result));
    try typed.define(lookup, try scan.ret(try scan.match(selected, &.{
        try found.ret(found_result), try missing.ret(try e.outcome(missing.body(), state, .rejected, .unknown_profile)),
    })));
    const entry = try typed.function("adaptive inference selection", &.{.{ .name = "input", .schema = try e.schema(InferenceInput) }}, try e.schema(Proposal), &.{});
    const root = try typed.body(entry);
    const request = try root.parameter("input");
    const prior = try e.field(root, request, InferenceInput, "state");
    const proposal = try e.field(root, request, InferenceInput, "command");
    const current_selection = try e.field(root, prior, State, "selection");
    const fresh = try root.branch();
    const stale = try root.branch();
    try typed.define(entry, try root.ret(try root.conditional(
        try root.equal(try e.field(root, proposal, InferenceSet, "expected_revision"), try e.field(root, current_selection, model.AdaptiveSelection, "control_revision")),
        try fresh.ret(try fresh.call(lookup, &.{ .{ .name = "input", .value = request }, .{ .name = "index", .value = try fresh.constant(u64, 0) } })),
        try stale.ret(try e.outcome(stale, prior, .rejected, .stale_revision)),
    )));
    return cached.finish(b, try a.interop.functionId(typed, entry));
}

fn supportsEffort(e: Emit, body: *a.Body, efforts: V, effort: V) !V {
    var found = try body.constant(bool, false);
    // The public effort enum has seven members; the frozen vector is bounded
    // by that same finite domain, with duplicates rejected on admission.
    for (0..7) |index| {
        const entry = try body.sequenceGet(efforts, try body.constant(u64, index));
        const some = try body.caseOf(entry, "some");
        const none = try body.caseOf(entry, "none");
        const yes = some.body();
        const matching = try yes.equal(try yes.enumTag(some.payload()), try yes.enumTag(effort));
        found = try body.match(entry, &.{ try some.ret(try yes.select(matching, try yes.constant(bool, true), found)), try none.ret(found) });
    }
    _ = e;
    return found;
}

/// Pure skill-state transition. No body is read or installed here: a proposed
/// state must still pass immutable-resource/context preparation before commit.
pub fn defineSkill(comptime P: type, c: authoring.Context, failure: Id) !Id {
    const cached = try c.builder.specialization(Id, "agent.adaptive.skill-control/v1", .{ @typeName(P), try c.builder.failureLiteral(failure) });
    if (cached.cached) |existing| return existing;
    const typed = try a.Context.init(c.builder);
    const e: Emit = .{ .context = c, .typed = typed, .failure = failure };
    const generator = SkillGenerator(P){ .e = e };
    return cached.finish(c.builder, try generator.define());
}

fn SkillGenerator(comptime P: type) type {
    return struct {
        e: Emit,
        const G = @This();
        const Input = SkillInput(P);
        const Skills = @FieldType(State, "skills");
        const Materialization = model.SkillMaterialization;

        fn define(g: G) !Id {
            const e = g.e;
            const t = e.typed;
            const rewrite = try t.function("adaptive skill materialization", &.{
                .{ .name = "input", .schema = try e.schema(Input) },  .{ .name = "entry", .schema = try e.schema(Skill) },
                .{ .name = "index", .schema = try t.scalar(u64) },    .{ .name = "items", .schema = try e.schema(Skills) },
                .{ .name = "found", .schema = try t.scalar(bool) },   .{ .name = "changed", .schema = try t.scalar(bool) },
                .{ .name = "removed", .schema = try t.scalar(bool) },
            }, try e.schema(Proposal), &.{});
            const b = try t.body(rewrite);
            const input = try b.parameter("input");
            const entry = try b.parameter("entry");
            const index = try b.parameter("index");
            const items = try b.parameter("items");
            const found = try b.parameter("found");
            const changed = try b.parameter("changed");
            const removed = try b.parameter("removed");
            const state = try e.field(b, input, Input, "state");
            const command = try e.field(b, input, Input, "command");
            const operation = try b.enumTag(try e.field(b, command, SkillSet, "operation"));
            const residency = try b.enumTag(try e.field(b, command, SkillSet, "residency"));
            const selected = try b.sequenceGet(try e.field(b, state, State, "skills"), index);
            const some = try b.caseOf(selected, "some");
            const none = try b.caseOf(selected, "none");
            const body = some.body();
            const old = some.payload();
            const matching = try body.branch();
            const other = try body.branch();
            const load = try matching.branch();
            const remove = try matching.branch();
            const unload = try remove.branch();
            const deactivate = try remove.branch();
            const same_residency = try load.equal(residency, try load.enumTag(try e.field(load, old, Materialization, "residency")));
            const compatible = try load.branch();
            const incompatible = try load.branch();
            const active = try e.field(compatible, old, Materialization, "active");
            const reactivated = try e.replace(compatible, Materialization, old, .{ .active = try compatible.constant(bool, true) });
            const load_result = try load.conditional(same_residency, try compatible.ret(try g.recur(compatible, rewrite, input, entry, index, try e.append(compatible, items, reactivated), try compatible.constant(bool, true), try e.either(compatible, changed, try compatible.equal(active, try compatible.constant(bool, false))), removed)), try incompatible.ret(try e.outcome(incompatible, state, .rejected, .invalid_operation)));
            const previously_active = try e.field(deactivate, old, Materialization, "active");
            const transient = try deactivate.equal(try deactivate.enumTag(try e.field(deactivate, old, Materialization, "residency")), try deactivate.constant(u32, 1));
            const deactivated = try e.replace(deactivate, Materialization, old, .{ .active = try deactivate.constant(bool, false) });
            const remove_result = try remove.conditional(try remove.equal(operation, try remove.constant(u32, 2)), try unload.ret(try g.recur(unload, rewrite, input, entry, index, items, try unload.constant(bool, true), try unload.constant(bool, true), try unload.constant(bool, true))), try deactivate.ret(try g.recur(deactivate, rewrite, input, entry, index, try e.append(deactivate, items, deactivated), try deactivate.constant(bool, true), try e.either(deactivate, changed, previously_active), try e.either(deactivate, removed, try e.both(deactivate, previously_active, transient)))));
            const matched_result = try matching.conditional(try matching.equal(operation, try matching.constant(u32, 0)), try load.ret(load_result), try remove.ret(remove_result));
            const scanned_result = try body.conditional(try e.sameText(body, try e.field(body, old, Materialization, "skill_id"), try e.field(body, command, SkillSet, "skill_id")), try matching.ret(matched_result), try other.ret(try g.recur(other, rewrite, input, entry, index, try e.append(other, items, old), found, changed, removed)));
            const end = none.body();
            const existing = try end.branch();
            const absent = try end.branch();
            const create = try absent.branch();
            const unknown = try absent.branch();
            const materialization = try create.product(try e.schema(Materialization), &.{
                .{ .name = "0", .value = try e.field(create, entry, Skill, "instructions") },
                .{ .name = "1", .value = try e.field(create, entry, Skill, "id") },
                .{ .name = "2", .value = try e.field(create, entry, Skill, "version") },
                .{ .name = "3", .value = try create.select(try create.equal(residency, try create.constant(u32, 0)), try e.literal(create, model.SkillResidency, .resident), try e.literal(create, model.SkillResidency, .transient)) },
                .{ .name = "4", .value = try create.constant(bool, true) },
                .{ .name = "5", .value = try e.field(create, input, Input, "watermark") },
            });
            const absent_result = try absent.conditional(try absent.equal(operation, try absent.constant(u32, 0)), try create.ret(try g.finish(create, input, try e.append(create, items, materialization), try create.constant(bool, true), removed)), try unknown.ret(try e.outcome(unknown, state, .rejected, .unknown_skill)));
            const end_result = try end.conditional(found, try existing.ret(try g.finish(existing, input, items, changed, removed)), try absent.ret(absent_result));
            try t.define(rewrite, try b.ret(try b.match(selected, &.{ try some.ret(scanned_result), try none.ret(end_result) })));

            const lookup = try t.function("adaptive skill catalog lookup", &.{ .{ .name = "input", .schema = try e.schema(Input) }, .{ .name = "index", .schema = try t.scalar(u64) } }, try e.schema(Proposal), &.{});
            const scan = try t.body(lookup);
            const request = try scan.parameter("input");
            const offset = try scan.parameter("index");
            const prior = try e.field(scan, request, Input, "state");
            const control = try e.field(scan, request, Input, "command");
            const candidate = try scan.sequenceGet(try e.field(scan, try e.field(scan, request, Input, "catalog"), Catalog, "skills"), offset);
            const present = try scan.caseOf(candidate, "some");
            const missing = try scan.caseOf(candidate, "none");
            const present_body = present.body();
            const yes = try present_body.branch();
            const no = try present_body.branch();
            const version_ok = try yes.branch();
            const version_bad = try yes.branch();
            const rewrite_result = try version_ok.call(rewrite, &.{
                .{ .name = "input", .value = request },                                .{ .name = "entry", .value = present.payload() },
                .{ .name = "index", .value = try version_ok.constant(u64, 0) },        .{ .name = "items", .value = try e.literal(version_ok, Skills, .{ .items = &.{} }) },
                .{ .name = "found", .value = try version_ok.constant(bool, false) },   .{ .name = "changed", .value = try version_ok.constant(bool, false) },
                .{ .name = "removed", .value = try version_ok.constant(bool, false) },
            });
            const version_result = try yes.conditional(try e.sameText(yes, try e.field(yes, present.payload(), Skill, "version"), try e.field(yes, control, SkillSet, "version")), try version_ok.ret(rewrite_result), try version_bad.ret(try e.outcome(version_bad, prior, .rejected, .version_mismatch)));
            const lookup_result = try present_body.conditional(try e.sameText(present_body, try e.field(present_body, present.payload(), Skill, "id"), try e.field(present_body, control, SkillSet, "skill_id")), try yes.ret(version_result), try no.ret(try no.call(lookup, &.{ .{ .name = "input", .value = request }, .{ .name = "index", .value = try e.increment(no, offset) } })));
            try t.define(lookup, try scan.ret(try scan.match(candidate, &.{ try present.ret(lookup_result), try missing.ret(try e.outcome(missing.body(), prior, .rejected, .unknown_skill)) })));
            return g.defineEntry(lookup);
        }

        fn recur(g: G, body: *a.Body, function: *const a.Function, input: V, entry: V, index: V, items: V, found: V, changed: V, removed: V) !V {
            return body.call(function, &.{
                .{ .name = "input", .value = input },     .{ .name = "entry", .value = entry }, .{ .name = "index", .value = try g.e.increment(body, index) },
                .{ .name = "items", .value = items },     .{ .name = "found", .value = found }, .{ .name = "changed", .value = changed },
                .{ .name = "removed", .value = removed },
            });
        }

        fn finish(g: G, body: *a.Body, input: V, skills: V, changed: V, removed: V) !V {
            const e = g.e;
            const state = try e.field(body, input, Input, "state");
            const unchanged = try body.branch();
            const update = try body.branch();
            const limits = try update.call(try skillCapacity(e), &.{
                .{ .name = "skills", .value = skills },                      .{ .name = "index", .value = try update.constant(u64, 0) },
                .{ .name = "active", .value = try update.constant(u64, 0) }, .{ .name = "bytes", .value = try update.constant(u64, 0) },
            });
            const selection = try e.field(update, state, State, "selection");
            const revision = try e.field(update, selection, model.AdaptiveSelection, "control_revision");
            const room = try update.branch();
            const full = try update.branch();
            const epoch = try e.field(room, state, State, "epoch");
            const generation = try e.field(room, state, State, "eviction_generation");
            const successor = try e.replace(room, State, state, .{
                .selection = try e.replace(room, model.AdaptiveSelection, selection, .{ .control_revision = try e.increment(room, revision) }),
                .skills = skills,
                .top_effort = try e.field(room, state, State, "top_effort"),
                .epoch = try room.select(removed, try e.increment(room, epoch), epoch),
                .epoch_reason = try room.select(removed, try e.literal(room, model.EpochReason, .eviction), try e.field(room, state, State, "epoch_reason")),
                .eviction_generation = try room.select(removed, try e.increment(room, generation), generation),
            });
            const admitted = try update.conditional(try e.both(update, limits, try update.less(revision, try e.field(update, input, Input, "maximum_revision"))), try room.ret(try e.outcome(room, successor, .proposed, .none)), try full.ret(try e.outcome(full, state, .rejected, .capacity)));
            return body.conditional(changed, try update.ret(admitted), try unchanged.ret(try e.outcome(unchanged, state, .unchanged, .none)));
        }

        fn defineEntry(g: G, lookup: *const a.Function) !Id {
            const e = g.e;
            const t = e.typed;
            const entry_function = try t.function("adaptive skill selection", &.{.{ .name = "input", .schema = try e.schema(Input) }}, try e.schema(Proposal), &.{});
            const b = try t.body(entry_function);
            const input = try b.parameter("input");
            const state = try e.field(b, input, Input, "state");
            const command = try e.field(b, input, Input, "command");
            const fresh = try b.branch();
            const stale = try b.branch();
            const load = try fresh.equal(try fresh.enumTag(try e.field(fresh, command, SkillSet, "operation")), try fresh.constant(u32, 0));
            const unchanged = try fresh.equal(try fresh.enumTag(try e.field(fresh, command, SkillSet, "residency")), try fresh.constant(u32, 2));
            const valid = try fresh.branch();
            const invalid = try fresh.branch();
            const result = try fresh.conditional(try fresh.equal(load, unchanged), try invalid.ret(try e.outcome(invalid, state, .rejected, .invalid_operation)), try valid.ret(try valid.call(lookup, &.{ .{ .name = "input", .value = input }, .{ .name = "index", .value = try valid.constant(u64, 0) } })));
            try t.define(entry_function, try b.ret(try b.conditional(try b.equal(try e.field(b, command, SkillSet, "expected_revision"), try e.field(b, try e.field(b, state, State, "selection"), model.AdaptiveSelection, "control_revision")), try fresh.ret(result), try stale.ret(try e.outcome(stale, state, .rejected, .stale_revision)))));
            return a.interop.functionId(t, entry_function);
        }
    };
}

fn skillCapacity(e: Emit) !*const a.Function {
    const t = e.typed;
    const b = e.context.builder;
    const cached = try b.specialization(Id, "agent.adaptive.skill-capacity/v1", .{ @intFromPtr(t), try b.failureLiteral(e.failure) });
    if (cached.cached) |existing| return a.interop.declaredFunction(t, existing);
    const function = try t.function("adaptive skill capacity", &.{
        .{ .name = "skills", .schema = try e.schema(@FieldType(State, "skills")) }, .{ .name = "index", .schema = try t.scalar(u64) },
        .{ .name = "active", .schema = try t.scalar(u64) },                         .{ .name = "bytes", .schema = try t.scalar(u64) },
    }, try t.scalar(bool), &.{});
    const body = try t.body(function);
    const skills = try body.parameter("skills");
    const index = try body.parameter("index");
    const active = try body.parameter("active");
    const bytes = try body.parameter("bytes");
    const room = try body.branch();
    const full = try body.branch();
    const item = try room.sequenceGet(skills, index);
    const some = try room.caseOf(item, "some");
    const none = try room.caseOf(item, "none");
    const next = some.body();
    const fault = try a.interop.literalFailure(t, e.failure, try a.interop.schema(t, b.values.items[e.failure].schema));
    const result = try next.call(function, &.{
        .{ .name = "skills", .value = skills },                                                                                                                          .{ .name = "index", .value = try e.increment(next, index) },
        .{ .name = "active", .value = try next.select(try e.field(next, some.payload(), model.SkillMaterialization, "active"), try e.increment(next, active), active) }, .{ .name = "bytes", .value = try next.checkedAdd(bytes, try e.field(next, try e.field(next, some.payload(), model.SkillMaterialization, "resource"), model.ArtifactReference, "bytes"), fault) },
    });
    const valid = try e.both(body, try body.less(active, try body.constant(u64, 5)), try body.less(bytes, try body.constant(u64, 128 * 1024 + 1)));
    try t.define(function, try body.ret(try body.conditional(valid, try room.ret(try room.match(item, &.{ try some.ret(result), try none.ret(try none.body().constant(bool, true)) })), try full.ret(try full.constant(bool, false)))));
    const id = try a.interop.functionId(t, function);
    _ = try cached.finish(b, id);
    return function;
}
