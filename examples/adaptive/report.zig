//! Structural report support is checked in the authored image. It establishes
//! membership in acquired evidence, never natural-language truth or entailment.
const protean = @import("protean");
const horos = @import("horos");
const t = @import("application_types");
const a = horos.authoring;
pub const Input = struct { report: t.Report, evidence_count: u64 };
pub const Function = a.Function(a.Signature(a.Shape(Input).contract.product, a.Shape(?t.ReportRejection)));
const Reason = @FieldType(t.ReportRejection, "reason");
fn V(comptime T: type) type {
    return *const a.Value(a.Shape(T));
}
const Emit = struct {
    context: protean.Context,
    fn fault(e: Emit) !*const a.FailureLiteral(a.Shape(t.Failure)) {
        return a.interop.literalFailure(e.context.author, try e.context.literal(t.Failure, .capacity));
    }
    fn next(e: Emit, b: anytype, index: V(u64)) !V(u64) {
        return b.checkedAdd(index, try b.constant(u64, 1), try e.fault());
    }
    fn some(e: Emit, b: anytype, index: V(u64)) !V(?u64) {
        return b.variant(try e.context.schema(?u64), "some", index);
    }
    fn reject(e: Emit, b: anytype, reason: Reason, claim: ?V(u64), position: ?V(u64)) !V(?t.ReportRejection) {
        const rejection = try b.product(try e.context.schema(t.ReportRejection), .{
            .reason = try e.context.literal(Reason, reason),
            .claim_index = if (claim) |index| try e.some(b, index) else try e.context.literal(?u64, null),
            .evidence_position = if (position) |index| try e.some(b, index) else try e.context.literal(?u64, null),
        });
        return b.variant(try e.context.schema(?t.ReportRejection), "some", rejection);
    }
    fn empty(e: Emit, b: anytype, text: anytype) !V(bool) {
        _ = e;
        return b.equal(try b.blobLength(text), try b.constant(u64, 0));
    }
};

pub fn define(context: protean.Context) !*const Function {
    const c = context.author;
    const e: Emit = .{ .context = context };
    const indices_schema = try context.schema(@FieldType(t.Claim, "evidence_indices"));
    const optional = try context.schema(?t.ReportRejection);
    // Each duplicate lookup is confined to the current claim's prior prefix.
    const contains = try c.function("report duplicate citation", .{ .indices = indices_schema, .index = try c.schema(u64), .end = try c.schema(u64), .target = try c.schema(u64) }, try c.schema(bool), &.{});
    const cb = try c.body(contains);
    const ci = try cb.parameter("index");
    const cx = try cb.parameter("indices");
    const ce = try cb.parameter("end");
    const ct = try cb.parameter("target");
    const checking = try cb.branch();
    const ended = try cb.branch();
    const value = try checking.variantPayload(try checking.sequenceGet(cx, ci), "some", try e.fault());
    const found = try checking.branch();
    const next = try checking.branch();
    const searched = try checking.conditional(try checking.equal(value, ct), try found.ret(try found.constant(bool, true)), try next.ret(try next.call(contains, .{ .indices = cx, .index = try e.next(next, ci), .end = ce, .target = ct })));
    try c.define(contains, try cb.ret(try cb.conditional(try cb.less(ci, ce), try checking.ret(searched), try ended.ret(try ended.constant(bool, false)))));

    const refs = try c.function("report citation membership", .{ .indices = indices_schema, .position = try c.schema(u64), .claim = try c.schema(u64), .count = try c.schema(u64) }, optional, &.{});
    const rb = try c.body(refs);
    const ri = try rb.parameter("indices");
    const rp = try rb.parameter("position");
    const rc = try rb.parameter("claim");
    const rn = try rb.parameter("count");
    const selected = try rb.sequenceGet(ri, rp);
    const present = try rb.caseOf(selected, "some");
    const absent = try rb.caseOf(selected, "none");
    const valid = try present.body().branch();
    const invalid = try present.body().branch();
    const duplicate = try valid.call(contains, .{ .indices = ri, .index = try valid.constant(u64, 0), .end = rp, .target = present.payload() });
    const repeated = try valid.branch();
    const unique = try valid.branch();
    const distinct = try valid.conditional(duplicate, try repeated.ret(try e.reject(repeated, .duplicate_evidence, rc, rp)), try unique.ret(try unique.call(refs, .{ .indices = ri, .position = try e.next(unique, rp), .claim = rc, .count = rn })));
    const member = try present.body().conditional(try present.body().less(present.payload(), rn), try valid.ret(distinct), try invalid.ret(try e.reject(invalid, .out_of_range, rc, rp)));
    try c.define(refs, try rb.ret(try rb.match(selected, .{ .some = try present.ret(member), .none = try absent.ret(try context.literal(?t.ReportRejection, null)) })));

    const claims = try c.function("report claim support", .{ .report = try context.schema(t.Report), .count = try c.schema(u64), .index = try c.schema(u64), .cited = try c.schema(bool) }, optional, &.{});
    const b = try c.body(claims);
    const report = try b.parameter("report");
    const count = try b.parameter("count");
    const index = try b.parameter("index");
    const cited = try b.parameter("cited");
    const item = try b.sequenceGet(try b.field(report, "claims"), index);
    const some = try b.caseOf(item, "some");
    const none = try b.caseOf(item, "none");
    const claim = some.payload();
    const body = some.body();
    const statement = try body.branch();
    const no_statement = try body.branch();
    const reasoning = try statement.branch();
    const no_reasoning = try statement.branch();
    const evidence = try reasoning.branch();
    const no_evidence = try reasoning.branch();
    const refs_value = try evidence.field(claim, "evidence_indices");
    const checked = try evidence.call(refs, .{ .indices = refs_value, .position = try evidence.constant(u64, 0), .claim = index, .count = count });
    const rejected = try evidence.caseOf(checked, "some");
    const accepted = try evidence.caseOf(checked, "none");
    const has_refs = try accepted.body().less(try accepted.body().constant(u64, 0), try accepted.body().sequenceLength(refs_value));
    const tail = try accepted.body().call(claims, .{ .report = report, .count = count, .index = try e.next(accepted.body(), index), .cited = try accepted.body().select(has_refs, try accepted.body().constant(bool, true), cited) });
    const references_result = try evidence.match(checked, .{ .some = try rejected.ret(checked), .none = try accepted.ret(tail) });
    const kind = try body.enumTag(try body.field(claim, "kind"));
    const hypothesis = try reasoning.equal(kind, try reasoning.constant(u32, @backingInt(@as(@FieldType(t.Claim, "kind"), .hypothesis))));
    const missing_refs = try reasoning.equal(try reasoning.sequenceLength(try reasoning.field(claim, "evidence_indices")), try reasoning.constant(u64, 0));
    const needs_refs = try reasoning.select(hypothesis, try reasoning.constant(bool, false), missing_refs);
    const evidence_result = try reasoning.conditional(needs_refs, try no_evidence.ret(try e.reject(no_evidence, .missing_evidence, index, null)), try evidence.ret(references_result));
    const observation = try statement.equal(kind, try statement.constant(u32, @backingInt(@as(@FieldType(t.Claim, "kind"), .observation))));
    const needs_reasoning = try statement.select(observation, try statement.constant(bool, false), try e.empty(statement, try statement.field(claim, "reasoning")));
    const reasoning_result = try statement.conditional(needs_reasoning, try no_reasoning.ret(try e.reject(no_reasoning, .missing_reasoning, index, null)), try reasoning.ret(evidence_result));
    const claim_result = try body.conditional(try e.empty(body, try body.field(claim, "statement")), try no_statement.ret(try e.reject(no_statement, .empty_statement, index, null)), try statement.ret(reasoning_result));
    const complete = try none.body().branch();
    const uncited = try none.body().branch();
    const end = try none.body().conditional(cited, try complete.ret(try context.literal(?t.ReportRejection, null)), try uncited.ret(try e.reject(uncited, .missing_evidence, null, null)));
    try c.define(claims, try b.ret(try b.match(item, .{ .some = try some.ret(claim_result), .none = try none.ret(end) })));

    const entry = try c.function("report validation", .{ .report = try context.schema(t.Report), .evidence_count = try c.schema(u64) }, optional, &.{});
    const root = try c.body(entry);
    const proposal = try root.parameter("report");
    const has_claims = try root.branch();
    const empty_report = try root.branch();
    const has_summary = try has_claims.branch();
    const empty_summary = try has_claims.branch();
    const result = try has_summary.call(claims, .{ .report = proposal, .count = try root.parameter("evidence_count"), .index = try has_summary.constant(u64, 0), .cited = try has_summary.constant(bool, false) });
    const summary = try has_claims.conditional(try e.empty(has_claims, try has_claims.field(proposal, "summary")), try empty_summary.ret(try e.reject(empty_summary, .empty_summary, null, null)), try has_summary.ret(result));
    try c.define(entry, try root.ret(try root.conditional(try root.equal(try root.sequenceLength(try root.field(proposal, "claims")), try root.constant(u64, 0)), try empty_report.ret(try e.reject(empty_report, .empty_report, null, null)), try has_claims.ret(summary))));
    return entry;
}
