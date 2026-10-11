//! Immutable work results keep the authored continuation independent of page size.
const std = @import("std");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const t = @import("application_types");
const P = t.P;
const Adapter = native.adaptive_responses.Adapter(P);
const Queries = native.repository.Tools(t);
pub fn digest(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}
fn same(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
pub fn reference(bytes: []const u8) t.model.ArtifactReference {
    return .{ .digest = digest(bytes), .bytes = bytes.len };
}
pub fn open(ctx: native.registry.ProjectionContext, ref: t.model.ArtifactReference) !contracts.Decoded(t.WorkArtifact) {
    const bytes = try ctx.object(.{ .digest = ref.digest, .bytes = ref.bytes }, 128 * 1024);
    defer ctx.allocator.free(bytes);
    var record = try contracts.decodeOwned(t.WorkArtifact, ctx.allocator, bytes);
    errdefer record.deinit();
    if (record.value.version != 1 or !same(&record.value.task, &ctx.task) or !same(&record.value.policy, &digest(ctx.profile))) return error.InvalidWorkArtifact;
    return record;
}
pub fn evidence(ctx: native.registry.ProjectionContext, ref: t.SourceEvidenceReference) !t.Evidence {
    var record = try open(ctx, ref.object);
    defer record.deinit();
    const item = record.value.evidence orelse return error.InvalidEvidence;
    if (!same(&item.snapshot, &ref.snapshot) or !same(item.path.bytes, ref.path.bytes) or !same(item.sha256.bytes, ref.sha256.bytes) or item.start != ref.start or item.end != ref.end or item.file_bytes != ref.file_bytes) return error.InvalidEvidence;
    return .{ .snapshot = item.snapshot, .path = .{ .bytes = try ctx.allocator.dupe(u8, item.path.bytes) }, .sha256 = .{ .bytes = try ctx.allocator.dupe(u8, item.sha256.bytes) }, .start = item.start, .end = item.end, .file_bytes = item.file_bytes, .content = .{ .bytes = try ctx.allocator.dupe(u8, item.content.bytes) } };
}
fn snapshot(ctx: native.registry.ProjectionContext) !native.repository.Snapshot {
    const root = (try native.json.parse(ctx.allocator, ctx.profile, .{ .bytes = 256 * 1024 })).value;
    const ref = try native.values.fromJson(native.registry.ObjectReference, ctx.allocator, native.json.get(root, "snapshot") orelse return error.InvalidConfiguration);
    return native.repository.Snapshot.openBorrowed(ctx.allocator, try ctx.object(ref, native.repository.maximum_snapshot_bytes));
}
/// Bind work to a function call in the exact captured response and its original
/// offered set. The authored image supplies its current context, not a host loop.
fn admit(ctx: native.registry.ProjectionContext, request: t.WorkRequest) !void {
    const expected: t.Action = switch (request.action) {
        .list => |value| .{ .list = value },
        .read => |value| .{ .read = value },
        .inspect => |value| .{ .inspect = .{ .evidence_index = value.evidence_index } },
    };
    return admitAction(ctx, request.context, request.call_id, expected);
}
pub fn admitAction(ctx: native.registry.ProjectionContext, source_context: t.model.AdaptiveContextReference, call_id: P.CallId, expected: t.Action) !void {
    const policy = try native.adaptive_responses.Admission(P).policy(ctx.allocator, ctx.profile);
    var context = try Adapter.Context.open(ctx, source_context, policy.audience.bytes);
    defer context.deinit();
    const bytes = try ctx.object(.{ .digest = context.value.source_request.digest, .bytes = context.value.source_request.bytes }, 2 * 1024 * 1024);
    var prepared = try contracts.decodeOwned(Adapter.Prepared, ctx.allocator, bytes);
    defer prepared.deinit();
    const captured = try ctx.object(.{ .digest = context.value.source_capture.digest, .bytes = context.value.source_capture.bytes }, 4 * 1024 * 1024);
    var raw = try contracts.decodeOwned(native.responses.Raw, ctx.allocator, captured);
    defer raw.deinit();
    const response = (try native.json.parse(ctx.allocator, raw.value.body.bytes, .{ .bytes = P.representation.provider_response_bytes })).value;
    const normalized = try native.responses.Adapter(P).normalize(ctx.allocator, prepared.value.request.invocation, native.json.get(response, "output") orelse return error.InvalidCapture);
    if (normalized != .output) return error.InvalidCapture;
    var found = false;
    for (normalized.output.items.items) |item| if (item == .function_call and same(item.function_call.call_id.bytes, call_id.bytes)) {
        const call = item.function_call;
        if (found or call.tool_ordinal_claim >= P.declaration_count or !prepared.value.request.offered[call.tool_ordinal_claim] or call.decoded_action != .decoded) return error.InvalidCapture;
        if (!same(try contracts.encodeOwned(t.Action, ctx.allocator, expected), try contracts.encodeOwned(t.Action, ctx.allocator, call.decoded_action.decoded))) return error.InvalidCapture;
        found = true;
    };
    if (!found) return error.InvalidCapture;
}
fn prepare(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
    var decoded = try contracts.decodeOwned(t.WorkRequest, ctx.allocator, bytes);
    defer decoded.deinit();
    const request = decoded.value;
    try admit(ctx, request);
    var source = try snapshot(ctx);
    defer source.deinit();
    var record: t.WorkArtifact = .{ .version = 1, .task = ctx.task, .policy = digest(ctx.profile), .context = request.context, .call_id = request.call_id, .request = request.action, .outcome = undefined, .evidence = null, .model_text = undefined };
    switch (request.action) {
        .list => |value| {
            const result = try Queries.list(ctx.allocator, source, value);
            record.outcome = .{ .list = .{ .request = value, .result = result.value } };
            record.model_text = result.model_text;
        },
        .read => |value| {
            const result = try Queries.read(ctx.allocator, source, value);
            record.outcome = .{ .read = .{ .request = value, .result = switch (result.value) {
                .found => |item| blk: {
                    record.evidence = item;
                    break :blk .{ .found = item };
                },
                .missing => |path| .{ .missing = path },
                .invalid => |reason| .{ .invalid = reason },
            } } };
            record.model_text = result.model_text;
        },
        .inspect => |value| {
            const item = try evidence(ctx, value.evidence);
            const file = source.get(item.path.bytes) orelse return error.InvalidEvidence;
            if (!same(&item.snapshot, &source.identity) or !same(item.sha256.bytes, &std.fmt.bytesToHex(file.sha256, .lower)) or item.end > file.contents.bytes.len or item.start > item.end or !same(item.content.bytes, file.contents.bytes[@intCast(item.start)..@intCast(item.end)])) return error.InvalidEvidence;
            var count: u32 = 0;
            var lines = std.mem.splitScalar(u8, item.content.bytes, '\n');
            while (lines.next()) |line| if (std.mem.indexOf(u8, line, "if (") != null or std.mem.indexOf(u8, line, "assert(") != null) {
                count += 1;
            };
            record.outcome = .{ .inspect = .{ .evidence_index = value.evidence_index, .guard_count = count } };
            record.model_text = .{ .bytes = try std.fmt.allocPrint(ctx.allocator, "Observed {d} lines containing if/assert syntax in evidence {d}. This lexical observation is not a correctness proof.", .{ count, value.evidence_index }) };
        },
    }
    return contracts.encodeOwned(t.WorkArtifact, ctx.allocator, record);
}
fn acquire(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
    ctx.checkCancellation() catch |err| return .{ .definitely_not_sent = err };
    return .{ .captured = try ctx.allocator.dupe(u8, bytes) };
}
fn interpret(ctx: native.registry.ProjectionContext, request: []const u8, prepared: []const u8, captured: []const u8) !native.registry.Projection {
    if (!same(prepared, captured) or !same(try prepare(ctx, request), prepared)) return error.InvalidCapture;
    var record = try contracts.decodeOwned(t.WorkArtifact, ctx.allocator, prepared);
    defer record.deinit();
    const ref = reference(prepared);
    const reply: t.WorkReply = .{ .artifact = ref, .evidence = if (record.value.evidence) |item| .{ .object = ref, .snapshot = item.snapshot, .path = item.path, .sha256 = item.sha256, .start = item.start, .end = item.end, .file_bytes = item.file_bytes } else null };
    const objects = try ctx.allocator.alloc([]const u8, 1);
    objects[0] = try ctx.allocator.dupe(u8, prepared);
    return .{ .reply = try contracts.encodeOwned(t.WorkReply, ctx.allocator, reply), .objects = objects };
}
pub fn declaration() native.Declaration {
    return .{ .identity = t.work_identity, .resource_role = "snapshot", .kind = .leaf, .background = true, .payload_schema = struct {
        fn schema(a: std.mem.Allocator) ![]u8 {
            return native.values.schemaBytes(t.WorkRequest, a);
        }
    }.schema, .resume_schema = struct {
        fn schema(a: std.mem.Allocator) ![]u8 {
            return native.values.schemaBytes(t.WorkReply, a);
        }
    }.schema, .capture = .{ .prepare = prepareWork, .acquire = acquire, .interpret = interpret } };
}
fn prepareInspection(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
    var request = try contracts.decodeOwned(t.WorkRequest, ctx.allocator, bytes);
    defer request.deinit();
    if (request.value.action != .inspect) return error.InvalidDeclaration;
    return prepare(ctx, bytes);
}
pub fn inspectionDeclaration() native.Declaration {
    var result = declaration();
    result.identity = t.inspect_identity;
    result.resource_role = "invariant-review";
    result.capture.?.prepare = prepareInspection;
    return result;
}

fn prepareWork(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
    var request = try contracts.decodeOwned(t.WorkRequest, ctx.allocator, bytes);
    defer request.deinit();
    if (request.value.action == .inspect) return error.InvalidDeclaration;
    return prepare(ctx, bytes);
}
