//! Pure authored adaptive control. These computations propose ordinary values;
//! the application commits them only after context preparation succeeds.
const horos = @import("horos");
const authoring = @import("authoring.zig");
const contracts = @import("protean_contracts");
const model = @import("model_invocation.zig");
const Effort = @import("model.zig").ReasoningEffort;
const a = horos.authoring;
const native = horos.data.schema.native;
fn V(comptime T: type) type {
    return *const a.Value(a.Shape(T));
}
pub fn Function(comptime Input: type) type {
    return a.Function(
        a.Signature(native.Fields(&.{"input"}, &.{a.Shape(Input)}), a.Shape(Proposal)),
    );
}

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
pub const InferenceCapability = struct {
    id: contracts.Text(64),
    efforts: @FieldType(model.AdaptiveInferenceProfile, "efforts"),
    effort_update: bool,
};
pub const ProfileChoice = struct { profile: InferenceCapability, digest: [32]u8 };
pub fn profileChoice(profile: model.AdaptiveInferenceProfile, digest: [32]u8) ProfileChoice {
    return .{
        .profile = .{
            .id = profile.id,
            .efforts = profile.efforts,
            .effort_update = profile.effort_update,
        },
        .digest = digest,
    };
}
pub const Skill = struct {
    id: contracts.Text(64),
    version: contracts.Text(64),
    instructions: model.ArtifactReference,
};
pub const Catalog = struct { skills: contracts.Vector(Skill, null) };
pub const Profiles = contracts.Vector(ProfileChoice, null);
pub const State = struct {
    selection: model.AdaptiveSelection,
    top_effort: Effort,
    epoch: u64,
    epoch_reason: model.EpochReason,
    eviction_generation: u64,
    skills: contracts.Vector(model.SkillMaterialization, null),
};
pub const Rejection = enum {
    none,
    stale_revision,
    unknown_profile,
    unsupported_effort,
    unknown_skill,
    version_mismatch,
    invalid_operation,
    capacity,
};
pub const Proposal = struct {
    state: State,
    disposition: enum { proposed, unchanged, rejected },
    rejection: Rejection,
};
pub const InferenceInput = struct { state: State, profiles: Profiles, command: InferenceSet };
pub fn SkillInput(comptime _: type) type {
    return struct { state: State, catalog: Catalog, command: SkillSet, watermark: u64 };
}

fn Emit(comptime Failure: type) type {
    return struct {
        context: authoring.Context,
        typed: *a.Context,
        failure: Failure,
        const E = @This();
        fn outcome(
            e: E,
            body: anytype,
            state: V(State),
            disposition: @FieldType(Proposal, "disposition"),
            rejection: Rejection,
        ) !V(Proposal) {
            return body.product(try e.context.schema(Proposal), .{
                .state = state,
                .disposition = try e.context.literal(
                    @FieldType(Proposal, "disposition"),
                    disposition,
                ),
                .rejection = try e.context.literal(Rejection, rejection),
            });
        }
        fn increment(e: E, body: anytype, value: V(u64)) !V(u64) {
            return body.checkedAdd(value, try body.constant(u64, 1), e.failure);
        }
        fn sameText(_: E, body: anytype, left: anytype, right: anytype) !V(bool) {
            return body.equal(try body.blobCompare(left, right), try body.constant(i8, 0));
        }
        fn either(_: E, body: anytype, left: V(bool), right: V(bool)) !V(bool) {
            return body.select(left, try body.constant(bool, true), right);
        }
        fn both(_: E, body: anytype, left: V(bool), right: V(bool)) !V(bool) {
            return body.select(left, right, try body.constant(bool, false));
        }
    };
}

/// `(InferenceInput) -> Proposal`, with no environmental effects. Lookup and
/// effort admission execute inside the authored program over frozen metadata.
pub fn defineInference(c: authoring.Context, failure: anytype) !*const Function(InferenceInput) {
    const b = c.builder;
    const cached = try b.specialization(horos.source.Id, "agent.adaptive.inference-control/v2", .{
        @intFromPtr(c.author),
        try a.interop.failureLiteralId(c.author, try a.interop.literalFailure(c.author, failure)),
    });
    if (cached.cached) |existing| return a.interop.refineFunction(
        c.author,
        try a.interop.declaredFunction(c.author, existing),
        try c.author.callable(
            .{ .input = try c.schema(InferenceInput) },
            try c.schema(Proposal),
            .{},
            .{ .use = .reusable },
        ),
    );
    const typed = c.author;
    const fault = try a.interop.literalFailure(typed, failure);
    const e: Emit(@TypeOf(fault)) = .{ .context = c, .typed = typed, .failure = fault };
    const lookup = try typed.function("adaptive profile lookup", .{
        .input = try e.context.schema(InferenceInput),
        .index = try typed.schema(u64),
    }, try e.context.schema(Proposal), &.{});
    try emitInferenceLookup(e, lookup);
    const entry = try inferenceEntry(e, lookup);
    _ = try cached.finish(b, try a.interop.functionId(c.author, entry));
    return entry;
}

fn emitInferenceLookup(e: anytype, lookup: anytype) !void {
    const typed = e.typed;
    const scan = try typed.body(lookup);
    const input = try scan.parameter("input");
    const index = try scan.parameter("index");
    const state = try scan.field(input, "state");
    const command = try scan.field(input, "command");
    const selection = try scan.field(state, "selection");
    const selected = try scan.sequenceGet(try scan.field(input, "profiles"), index);
    const found = try scan.caseOf(selected, "some");
    const missing = try scan.caseOf(selected, "none");
    const current = found.body();
    const choice = found.payload();
    const profile = try current.field(choice, "profile");
    const match = try current.branch();
    const next = try current.branch();
    const matched_result = try inferenceMatch(e, match, state, selection, command, choice, profile);
    const next_result = try next.call(lookup, .{
        .input = input,
        .index = try e.increment(next, index),
    });
    const found_result = try current.conditional(
        try e.sameText(
            current,
            try current.field(profile, "id"),
            try current.field(command, "profile_id"),
        ),
        try match.ret(matched_result),
        try next.ret(next_result),
    );
    try typed.define(
        lookup,
        try scan.ret(
            try scan.match(selected, .{
                .some = try found.ret(found_result),
                .none = try missing.ret(
                    try e.outcome(missing.body(), state, .rejected, .unknown_profile),
                ),
            }),
        ),
    );
}

fn inferenceEntry(e: anytype, lookup: anytype) !*const Function(InferenceInput) {
    const typed = e.typed;
    const entry = try typed.function("adaptive inference selection", .{
        .input = try e.context.schema(InferenceInput),
    }, try e.context.schema(Proposal), &.{});
    const root = try typed.body(entry);
    const request = try root.parameter("input");
    const prior = try root.field(request, "state");
    const proposal = try root.field(request, "command");
    const current_selection = try root.field(prior, "selection");
    const fresh = try root.branch();
    const stale = try root.branch();
    try typed.define(entry, try root.ret(try root.conditional(
        try root.equal(
            try root.field(proposal, "expected_revision"),
            try root.field(current_selection, "control_revision"),
        ),
        try fresh.ret(
            try fresh.call(lookup, .{ .input = request, .index = try fresh.constant(u64, 0) }),
        ),
        try stale.ret(try e.outcome(stale, prior, .rejected, .stale_revision)),
    )));
    return entry;
}

fn inferenceMatch(
    e: anytype,
    match: anytype,
    state: V(State),
    selection: V(model.AdaptiveSelection),
    command: V(InferenceSet),
    choice: V(ProfileChoice),
    profile: V(InferenceCapability),
) !V(Proposal) {
    const effort = try match.field(command, "effort");
    const supported = try supportsEffort(e, match, try match.field(profile, "efforts"), effort);
    const admitted = try match.branch();
    const unsupported = try match.branch();
    const same_profile = try e.sameText(
        admitted,
        try admitted.field(selection, "profile_id"),
        try admitted.field(command, "profile_id"),
    );
    const same_effort = try admitted.equal(
        try admitted.enumTag(try admitted.field(selection, "effective_effort")),
        try admitted.enumTag(effort),
    );
    const unchanged = try admitted.branch();
    const changed = try admitted.branch();
    const changed_result = try inferenceChanged(
        e,
        changed,
        state,
        selection,
        command,
        choice,
        profile,
        effort,
        same_profile,
    );
    const admitted_result = try admitted.conditional(
        try admitted.select(same_profile, same_effort, try admitted.constant(bool, false)),
        try unchanged.ret(try e.outcome(unchanged, state, .unchanged, .none)),
        try changed.ret(changed_result),
    );
    return match.conditional(
        supported,
        try admitted.ret(admitted_result),
        try unsupported.ret(try e.outcome(unsupported, state, .rejected, .unsupported_effort)),
    );
}

fn inferenceChanged(
    e: anytype,
    changed: anytype,
    state: V(State),
    selection: V(model.AdaptiveSelection),
    command: V(InferenceSet),
    choice: V(ProfileChoice),
    profile: V(InferenceCapability),
    effort: V(Effort),
    same_profile: V(bool),
) !V(Proposal) {
    const revision = try changed.field(selection, "control_revision");
    const room = changed;
    const keeps_epoch = try room.select(
        same_profile,
        try room.field(profile, "effort_update"),
        try room.constant(bool, false),
    );
    const old_epoch = try room.field(state, "epoch");
    const epoch = try room.select(keeps_epoch, old_epoch, try e.increment(room, old_epoch));
    const next_selection = try room.update(selection, .{
        .profile_id = try room.field(command, "profile_id"),
        .profile_digest = try room.field(choice, "digest"),
        .effective_effort = effort,
        .control_revision = try e.increment(room, revision),
    });
    const reason = try room.select(
        same_profile,
        try e.context.literal(model.EpochReason, .effort_change),
        try e.context.literal(model.EpochReason, .model_change),
    );
    const successor = try room.update(state, .{
        .selection = next_selection,
        .top_effort = try room.select(keeps_epoch, try room.field(state, "top_effort"), effort),
        .epoch = epoch,
        .epoch_reason = try room.select(keeps_epoch, try room.field(state, "epoch_reason"), reason),
    });
    return e.outcome(room, successor, .proposed, .none);
}

fn supportsEffort(
    e: anytype,
    body: anytype,
    efforts: V(@FieldType(InferenceCapability, "efforts")),
    effort: V(Effort),
) !V(bool) {
    var found = try body.constant(bool, false);
    // The public effort enum has seven members; the frozen vector is bounded
    // by that same finite domain, with duplicates rejected on admission.
    for (0..7) |index| {
        const entry = try body.sequenceGet(efforts, try body.constant(u64, index));
        const some = try body.caseOf(entry, "some");
        const none = try body.caseOf(entry, "none");
        const yes = some.body();
        const matching = try yes.equal(try yes.enumTag(some.payload()), try yes.enumTag(effort));
        found = try body.match(entry, .{
            .some = try some.ret(try yes.select(matching, try yes.constant(bool, true), found)),
            .none = try none.ret(found),
        });
    }
    _ = e;
    return found;
}

/// Pure skill-state transition. No body is read or installed here: a proposed
/// state must still pass immutable-resource/context preparation before commit.
pub fn defineSkill(
    comptime P: type,
    c: authoring.Context,
    failure: anytype,
) !*const Function(SkillInput(P)) {
    const cached = try c.builder.specialization(
        horos.source.Id,
        "agent.adaptive.skill-control/v2",
        .{
            @intFromPtr(c.author),
            @typeName(P),
            try a.interop.failureLiteralId(
                c.author,
                try a.interop.literalFailure(c.author, failure),
            ),
        },
    );
    if (cached.cached) |existing| return a.interop.refineFunction(
        c.author,
        try a.interop.declaredFunction(c.author, existing),
        try c.author.callable(
            .{ .input = try c.schema(SkillInput(P)) },
            try c.schema(Proposal),
            .{},
            .{ .use = .reusable },
        ),
    );
    const typed = c.author;
    const fault = try a.interop.literalFailure(typed, failure);
    const e: Emit(@TypeOf(fault)) = .{ .context = c, .typed = typed, .failure = fault };
    const generator = SkillGenerator(P, @TypeOf(e)){ .e = e };
    const entry = try generator.define();
    _ = try cached.finish(c.builder, try a.interop.functionId(c.author, entry));
    return entry;
}

fn SkillGenerator(comptime P: type, comptime E: type) type {
    return struct {
        e: E,
        const G = @This();
        const Input = SkillInput(P);
        const Skills = @FieldType(State, "skills");
        const Materialization = model.SkillMaterialization;

        fn define(g: G) !*const Function(Input) {
            const e = g.e;
            const t = e.typed;
            const rewrite = try t.function("adaptive skill materialization", .{
                .input = try e.context.schema(Input),
                .entry = try e.context.schema(Skill),
                .index = try t.schema(u64),
                .items = try e.context.schema(Skills),
                .found = try t.schema(bool),
                .changed = try t.schema(bool),
                .removed = try t.schema(bool),
            }, try e.context.schema(Proposal), &.{});
            try g.emitRewrite(rewrite);
            const lookup = try t.function("adaptive skill catalog lookup", .{
                .input = try e.context.schema(Input),
                .index = try t.schema(u64),
            }, try e.context.schema(Proposal), &.{});
            try g.emitLookup(rewrite, lookup);
            return g.defineEntry(lookup);
        }

        fn emitRewrite(g: G, rewrite: anytype) !void {
            const e = g.e;
            const t = e.typed;
            const b = try t.body(rewrite);
            const input = try b.parameter("input");
            const entry = try b.parameter("entry");
            const index = try b.parameter("index");
            const items = try b.parameter("items");
            const found = try b.parameter("found");
            const changed = try b.parameter("changed");
            const removed = try b.parameter("removed");
            const state = try b.field(input, "state");
            const command = try b.field(input, "command");
            const operation = try b.enumTag(try b.field(command, "operation"));
            const residency = try b.enumTag(try b.field(command, "residency"));
            const selected = try b.sequenceGet(try b.field(state, "skills"), index);
            const some = try b.caseOf(selected, "some");
            const none = try b.caseOf(selected, "none");
            const cursor = .{
                .rewrite = rewrite,
                .input = input,
                .entry = entry,
                .index = index,
                .items = items,
                .found = found,
                .changed = changed,
                .removed = removed,
                .state = state,
                .command = command,
                .operation = operation,
                .residency = residency,
            };
            const scanned_result = try g.matchMaterialization(cursor, some);
            const end_result = try g.endMaterialization(cursor, none);
            try t.define(
                rewrite,
                try b.ret(
                    try b.match(selected, .{
                        .some = try some.ret(scanned_result),
                        .none = try none.ret(end_result),
                    }),
                ),
            );
        }

        fn matchMaterialization(g: G, cursor: anytype, some: anytype) !V(Proposal) {
            const e = g.e;
            const body = some.body();
            const old = some.payload();
            const matching = try body.branch();
            const other = try body.branch();
            const load = try matching.branch();
            const remove = try matching.branch();
            const unload = try remove.branch();
            const deactivate = try remove.branch();
            const load_result = try g.loadMaterialization(cursor, load, old);
            const remove_result = try g.removeMaterialization(
                cursor,
                remove,
                unload,
                deactivate,
                old,
            );
            const matched_result = try matching.conditional(
                try matching.equal(cursor.operation, try matching.constant(u32, 0)),
                try load.ret(load_result),
                try remove.ret(remove_result),
            );
            return body.conditional(
                try e.sameText(
                    body,
                    try body.field(old, "skill_id"),
                    try body.field(cursor.command, "skill_id"),
                ),
                try matching.ret(matched_result),
                try other.ret(
                    try g.recur(
                        other,
                        cursor.rewrite,
                        cursor.input,
                        cursor.entry,
                        cursor.index,
                        try other.append(cursor.items, old, .{}),
                        cursor.found,
                        cursor.changed,
                        cursor.removed,
                    ),
                ),
            );
        }

        fn loadMaterialization(
            g: G,
            cursor: anytype,
            load: anytype,
            old: V(Materialization),
        ) !V(
            Proposal,
        ) {
            const e = g.e;
            const same_residency = try load.equal(
                cursor.residency,
                try load.enumTag(try load.field(old, "residency")),
            );
            const compatible = try load.branch();
            const incompatible = try load.branch();
            const active = try compatible.field(old, "active");
            const reactivated = try compatible.update(old, .{
                .active = try compatible.constant(bool, true),
            });
            return load.conditional(
                same_residency,
                try compatible.ret(
                    try g.recur(
                        compatible,
                        cursor.rewrite,
                        cursor.input,
                        cursor.entry,
                        cursor.index,
                        try compatible.append(cursor.items, reactivated, .{}),
                        try compatible.constant(bool, true),
                        try e.either(
                            compatible,
                            cursor.changed,
                            try compatible.equal(active, try compatible.constant(bool, false)),
                        ),
                        cursor.removed,
                    ),
                ),
                try incompatible.ret(
                    try e.outcome(incompatible, cursor.state, .rejected, .invalid_operation),
                ),
            );
        }

        fn removeMaterialization(
            g: G,
            cursor: anytype,
            remove: anytype,
            unload: anytype,
            deactivate: anytype,
            old: V(Materialization),
        ) !V(Proposal) {
            const e = g.e;
            const previously_active = try deactivate.field(old, "active");
            const transient = try deactivate.equal(
                try deactivate.enumTag(try deactivate.field(old, "residency")),
                try deactivate.constant(u32, 1),
            );
            const deactivated = try deactivate.update(old, .{
                .active = try deactivate.constant(bool, false),
            });
            return remove.conditional(
                try remove.equal(cursor.operation, try remove.constant(u32, 2)),
                try unload.ret(
                    try g.recur(
                        unload,
                        cursor.rewrite,
                        cursor.input,
                        cursor.entry,
                        cursor.index,
                        cursor.items,
                        try unload.constant(bool, true),
                        try unload.constant(bool, true),
                        try unload.constant(bool, true),
                    ),
                ),
                try deactivate.ret(
                    try g.recur(
                        deactivate,
                        cursor.rewrite,
                        cursor.input,
                        cursor.entry,
                        cursor.index,
                        try deactivate.append(cursor.items, deactivated, .{}),
                        try deactivate.constant(bool, true),
                        try e.either(deactivate, cursor.changed, previously_active),
                        try e.either(
                            deactivate,
                            cursor.removed,
                            try e.both(deactivate, previously_active, transient),
                        ),
                    ),
                ),
            );
        }

        fn endMaterialization(g: G, cursor: anytype, none: anytype) !V(Proposal) {
            const e = g.e;
            const end = none.body();
            const existing = try end.branch();
            const absent = try end.branch();
            const create = try absent.branch();
            const unknown = try absent.branch();
            const materialization = try create.product(try e.context.schema(
                Materialization,
            ), .{
                .resource = try create.field(cursor.entry, "instructions"),
                .skill_id = try create.field(cursor.entry, "id"),
                .version = try create.field(cursor.entry, "version"),
                .residency = try create.select(
                    try create.equal(cursor.residency, try create.constant(u32, 0)),
                    try e.context.literal(model.SkillResidency, .resident),
                    try e.context.literal(model.SkillResidency, .transient),
                ),
                .active = try create.constant(bool, true),
                .introduced_at = try create.field(cursor.input, "watermark"),
            });
            const absent_result = try absent.conditional(
                try absent.equal(cursor.operation, try absent.constant(u32, 0)),
                try create.ret(
                    try g.finish(
                        create,
                        cursor.input,
                        try create.append(cursor.items, materialization, .{}),
                        try create.constant(bool, true),
                        cursor.removed,
                    ),
                ),
                try unknown.ret(try e.outcome(unknown, cursor.state, .rejected, .unknown_skill)),
            );
            return end.conditional(
                cursor.found,
                try existing.ret(
                    try g.finish(
                        existing,
                        cursor.input,
                        cursor.items,
                        cursor.changed,
                        cursor.removed,
                    ),
                ),
                try absent.ret(absent_result),
            );
        }

        fn emitLookup(g: G, rewrite: anytype, lookup: anytype) !void {
            const e = g.e;
            const t = e.typed;
            const scan = try t.body(lookup);
            const request = try scan.parameter("input");
            const offset = try scan.parameter("index");
            const prior = try scan.field(request, "state");
            const control = try scan.field(request, "command");
            const candidate = try scan.sequenceGet(
                try scan.field(try scan.field(request, "catalog"), "skills"),
                offset,
            );
            const present = try scan.caseOf(candidate, "some");
            const missing = try scan.caseOf(candidate, "none");
            const present_body = present.body();
            const yes = try present_body.branch();
            const no = try present_body.branch();
            const version_result = try g.catalogVersion(
                rewrite,
                yes,
                present,
                request,
                control,
                prior,
            );
            const lookup_result = try present_body.conditional(
                try e.sameText(
                    present_body,
                    try present_body.field(present.payload(), "id"),
                    try present_body.field(control, "skill_id"),
                ),
                try yes.ret(version_result),
                try no.ret(
                    try no.call(lookup, .{
                        .input = request,
                        .index = try e.increment(no, offset),
                    }),
                ),
            );
            try t.define(
                lookup,
                try scan.ret(
                    try scan.match(candidate, .{
                        .some = try present.ret(lookup_result),
                        .none = try missing.ret(
                            try e.outcome(missing.body(), prior, .rejected, .unknown_skill),
                        ),
                    }),
                ),
            );
        }

        fn catalogVersion(
            g: G,
            rewrite: anytype,
            yes: anytype,
            present: anytype,
            request: V(Input),
            control: V(SkillSet),
            prior: V(State),
        ) !V(Proposal) {
            const e = g.e;
            const version_ok = try yes.branch();
            const version_bad = try yes.branch();
            const rewrite_result = try version_ok.call(rewrite, .{
                .input = request,
                .entry = present.payload(),
                .index = try version_ok.constant(u64, 0),
                .items = try e.context.literal(Skills, .{ .items = &.{} }),
                .found = try version_ok.constant(bool, false),
                .changed = try version_ok.constant(bool, false),
                .removed = try version_ok.constant(bool, false),
            });
            return yes.conditional(
                try e.sameText(
                    yes,
                    try yes.field(present.payload(), "version"),
                    try yes.field(control, "version"),
                ),
                try version_ok.ret(rewrite_result),
                try version_bad.ret(
                    try e.outcome(version_bad, prior, .rejected, .version_mismatch),
                ),
            );
        }

        fn recur(
            g: G,
            body: anytype,
            function: anytype,
            input: V(Input),
            entry: V(Skill),
            index: V(u64),
            items: V(Skills),
            found: V(bool),
            changed: V(bool),
            removed: V(bool),
        ) !V(Proposal) {
            return body.call(function, .{
                .input = input,
                .entry = entry,
                .index = try g.e.increment(body, index),
                .items = items,
                .found = found,
                .changed = changed,
                .removed = removed,
            });
        }

        fn finish(
            g: G,
            body: anytype,
            input: V(Input),
            skills: V(Skills),
            changed: V(bool),
            removed: V(bool),
        ) !V(Proposal) {
            const e = g.e;
            const state = try body.field(input, "state");
            const unchanged = try body.branch();
            const update = try body.branch();
            const selection = try update.field(state, "selection");
            const revision = try update.field(selection, "control_revision");
            const room = update;
            const epoch = try room.field(state, "epoch");
            const generation = try room.field(state, "eviction_generation");
            const successor = try room.update(state, .{
                .selection = try room.update(selection, .{
                    .control_revision = try e.increment(room, revision),
                }),
                .skills = skills,
                .top_effort = try room.field(state, "top_effort"),
                .epoch = try room.select(removed, try e.increment(room, epoch), epoch),
                .epoch_reason = try room.select(
                    removed,
                    try e.context.literal(model.EpochReason, .eviction),
                    try room.field(state, "epoch_reason"),
                ),
                .eviction_generation = try room.select(
                    removed,
                    try e.increment(room, generation),
                    generation,
                ),
            });
            const admitted = try e.outcome(room, successor, .proposed, .none);
            return body.conditional(
                changed,
                try update.ret(admitted),
                try unchanged.ret(try e.outcome(unchanged, state, .unchanged, .none)),
            );
        }

        fn defineEntry(g: G, lookup: anytype) !*const Function(Input) {
            const e = g.e;
            const t = e.typed;
            const entry_function = try t.function("adaptive skill selection", .{
                .input = try e.context.schema(Input),
            }, try e.context.schema(Proposal), &.{});
            const b = try t.body(entry_function);
            const input = try b.parameter("input");
            const state = try b.field(input, "state");
            const command = try b.field(input, "command");
            const fresh = try b.branch();
            const stale = try b.branch();
            const load = try fresh.equal(
                try fresh.enumTag(try fresh.field(command, "operation")),
                try fresh.constant(u32, 0),
            );
            const unchanged = try fresh.equal(
                try fresh.enumTag(try fresh.field(command, "residency")),
                try fresh.constant(u32, 2),
            );
            const valid = try fresh.branch();
            const invalid = try fresh.branch();
            const result = try fresh.conditional(
                try fresh.equal(load, unchanged),
                try invalid.ret(try e.outcome(invalid, state, .rejected, .invalid_operation)),
                try valid.ret(
                    try valid.call(lookup, .{
                        .input = input,
                        .index = try valid.constant(u64, 0),
                    }),
                ),
            );
            try t.define(
                entry_function,
                try b.ret(
                    try b.conditional(
                        try b.equal(
                            try b.field(command, "expected_revision"),
                            try b.field(try b.field(state, "selection"), "control_revision"),
                        ),
                        try fresh.ret(result),
                        try stale.ret(try e.outcome(stale, state, .rejected, .stale_revision)),
                    ),
                ),
            );
            return entry_function;
        }
    };
}
