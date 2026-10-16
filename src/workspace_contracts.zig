//! Model actions select ordinary Horos programs and native workspace operations.
//! Text fields carry canonical runtime-schema JSON; they are never native code.
const c = @import("contracts.zig");
pub const identity = "protean-workspace/1";
pub const Ref = struct {
    kind: enum { program, work, port, value, schema, source, provenance, view },
    id: c.Text(64),
};
pub const Page = struct { offset: u64 = 0, maximum: u32 = 16384 };
pub const ValueInput = union(enum) {
    reference: Ref,
    inline_json: struct { schema: Ref, json_text: c.Utf8 },
};
pub const SourceInput = union(enum) { json_text: c.Utf8, reference: Ref };
pub const SourceKind = enum { source_records, component_recipe };
pub const Materialization = union(enum) { value: ValueInput, snapshot: struct { path: c.Utf8, offset: u64, maximum: u64 }, authorized_input: c.Utf8 };
pub const Policy = struct {
    stop: enum { next_slice, next_exposed_event, terminal } = .next_slice,
    continuation: enum { explicit_only, owner_scheduled } = .explicit_only,
};
pub const Expected = struct { work: Ref, execution_revision: u64, control_revision: u64 };
pub const Exposure = struct { effect: u64, class: enum { observation, input, alternative } };
pub const Interpretation = union(enum) {
    none: struct {},
    model: struct { port: Ref, generation: u64, profile_id: c.Text(64), effort: c.Text(16), subproblem: c.Utf8, inputs: c.Vector(Ref, null) },
    snapshot: struct { port: Ref, generation: u64, path: c.Utf8, offset: u64, maximum: u64 },
};
pub const Program = union(enum) {
    describe: struct { section: enum { source_records, values, components, examples, bindings }, page: Page },
    build: struct { source: SourceInput, source_kind: SourceKind, exposures: c.Vector(Exposure, null) },
    inspect: struct { program: Ref, page: Page },
};
pub const Work = union(enum) {
    start: struct { program: Ref, input: ValueInput, policy: Policy },
    inspect: struct { work: Ref },
    advance: Expected,
    delegate: struct { expected: Expected, policy: Policy, interpretation: Interpretation = .{ .none = .{} } },
    wait: struct { works: c.Vector(Ref, null), after: u64 },
    interact: struct { expected: Expected, port: Ref, generation: u64, command: union(enum) { resume_value: ValueInput, finish: struct {} } },
    collect: struct { works: c.Vector(Ref, null) },
    park: Expected,
    cancel: struct { expected: Expected, reason: c.Text(256) },
};
pub const Context = union(enum) {
    inspect: struct { page: Page },
    materialize: struct { input: Materialization, sources: c.Vector(Ref, null) },
    select: struct { values: c.Vector(Ref, null) },
    expand: struct { reference: Ref, page: Page },
};
pub const Command = union(enum) { program: Program, work: Work, context: Context };
/// Full observations remain retained; only the requested page enters inference.
/// A rejection is ordinary result data and never changes the next action set.
pub const Reply = struct {
    disposition: enum { observed, admitted, rejected },
    observation_json: c.Utf8,
    selected_view: ?Ref = null,
    program: ?Ref = null,
    evidence: ?Ref = null,
};
