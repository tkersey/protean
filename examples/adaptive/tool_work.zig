//! Construction and execution use ordinary captured worker occurrences.
const std = @import("std");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const t = @import("application_types");
const work = @import("work.zig");
const resources = @import("tool_resources.zig");
const wire = contracts.tool_construction;
const engine = native.tool_construction;
const Prepared = struct {
    task: [16]u8,
    policy: [32]u8,
    request: t.ToolRequest,
    catalog: contracts.Bytes(null),
    program: ?wire.Program = null,
    input: ?wire.Input = null,
    input_ref: ?t.model.ArtifactReference = null,
    rejected: ?t.ToolFailure = null,
};
const Captured = struct { prepared: [32]u8, artifact: t.ToolArtifact, program: ?contracts.Bytes(null) };
fn same(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn failure(stage: @FieldType(t.ToolFailure, "stage"), err: anyerror) t.ToolFailure {
    return .{ .stage = stage, .reason = .{ .bytes = @errorName(err) } };
}
pub fn open(ctx: native.registry.ProjectionContext, ref: t.model.ArtifactReference) !contracts.Decoded(t.ToolArtifact) {
    const bytes = try ctx.object(.{ .digest = ref.digest, .bytes = ref.bytes }, std.math.cast(usize, ref.bytes) orelse return error.Capacity);
    defer ctx.allocator.free(bytes);
    var record = try contracts.decodeOwned(t.ToolArtifact, ctx.allocator, bytes);
    errdefer record.deinit();
    if (!same(&record.value.task, &ctx.task) or !same(&record.value.policy, &work.digest(ctx.profile))) return error.InvalidToolArtifact;
    return record;
}
fn resolveRun(ctx: native.registry.ProjectionContext, policy: t.ToolPolicy, prepared: *Prepared) !void {
    const request = prepared.request.action.run;
    const input_ref = try resources.parseReference(request.input_ref.bytes);
    var allowed = false;
    for (policy.inputs.items) |input| allowed = allowed or resources.sameReference(input.object, input_ref);
    if (!allowed) return error.UnauthorizedInput;
    const tool_ref = try resources.parseReference(request.tool_ref.bytes);
    const bytes = try ctx.object(.{ .digest = tool_ref.digest, .bytes = tool_ref.bytes }, std.math.cast(usize, tool_ref.bytes) orelse return error.Capacity);
    const program = try contracts.decodeOwned(wire.Program, ctx.allocator, bytes);
    if (program.value.version != 2 or !same(&program.value.task, &ctx.task) or !same(&program.value.policy, &prepared.policy) or !same(&program.value.catalog, &policy.catalog.digest)) return error.UnauthorizedProgram;
    const input_bytes = try ctx.object(.{ .digest = input_ref.digest, .bytes = input_ref.bytes }, std.math.cast(usize, input_ref.bytes) orelse return error.Capacity);
    prepared.program = program.value;
    prepared.input = (try contracts.decodeOwned(wire.Input, ctx.allocator, input_bytes)).value;
    prepared.input_ref = input_ref;
}
fn prepare(ctx: native.registry.ProjectionContext, bytes: []const u8, comptime build: bool) ![]u8 {
    var request = try contracts.decodeOwned(t.ToolRequest, ctx.allocator, bytes);
    defer request.deinit();
    if ((request.value.action == .build) != build) return error.InvalidDeclaration;
    const expected: t.Action = if (build) .{ .tool_build = request.value.action.build } else .{ .tool_run = request.value.action.run };
    try work.admitAction(ctx, request.value.context, request.value.call_id, expected);
    const policy = try resources.policy(ctx);
    if (if (build) !policy.build else !policy.run) return error.Unauthorized;
    const catalog = try ctx.object(.{ .digest = policy.catalog.digest, .bytes = policy.catalog.bytes }, std.math.cast(usize, policy.catalog.bytes) orelse return error.Capacity);
    var prepared: Prepared = .{ .task = ctx.task, .policy = work.digest(ctx.profile), .request = request.value, .catalog = .{ .bytes = catalog } };
    if (!build) resolveRun(ctx, policy, &prepared) catch |err| {
        prepared.rejected = failure(.admission, err);
    };
    return contracts.encodeOwned(Prepared, ctx.allocator, prepared);
}
fn prepareBuild(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
    return prepare(ctx, bytes, true);
}
fn prepareRun(ctx: native.registry.ProjectionContext, bytes: []const u8) ![]u8 {
    return prepare(ctx, bytes, false);
}
fn render(a: std.mem.Allocator, artifact: t.ToolArtifact, program: ?wire.Program) !t.P.ResultText {
    var value = native.json.object();
    switch (artifact.outcome) {
        .rejected => |reason| {
            try native.json.put(a, &value, "disposition", native.json.string("rejected"));
            try native.json.put(a, &value, "stage", native.json.string(@tagName(reason.stage)));
            try native.json.put(a, &value, "reason", native.json.string(reason.reason.bytes));
        },
        .built => |ref| {
            const built = (program orelse return error.InvalidCapture).built;
            try native.json.put(a, &value, "disposition", native.json.string("structurally_admitted"));
            try native.json.put(a, &value, "tool_ref", native.json.string(try resources.referenceText(a, ref)));
            inline for (.{ "input", "output", "failure" }) |name| {
                const identity = std.fmt.bytesToHex(work.digest(@field(built.interface, name).bytes), .lower);
                try native.json.put(a, &value, name ++ "_schema_sha256", native.json.string(try a.dupe(u8, &identity)));
            }
        },
        .ran => |result| {
            try native.json.put(a, &value, "disposition", native.json.string("completed"));
            try native.json.put(a, &value, "tool_ref", native.json.string(try resources.referenceText(a, result.program)));
            try native.json.put(a, &value, "input_ref", native.json.string(try resources.referenceText(a, result.input)));
            var decoded = try contracts.decodeOwned(t.tool_types.Table, a, result.value.bytes);
            defer decoded.deinit();
            try native.json.put(a, &value, "value", try native.values.toJson(t.tool_types.Table, a, decoded.value));
        },
    }
    return .{ .bytes = try native.json.canonical(a, value) };
}
fn compute(a: std.mem.Allocator, profile: []const u8, cancellation: ?*const std.atomic.Value(bool), prepared: Prepared, program_bytes: *?contracts.Bytes(null)) !@FieldType(t.ToolArtifact, "outcome") {
    if (prepared.rejected) |reason| return .{ .rejected = reason };
    if (cancellation) |flag| if (flag.load(.acquire)) return error.Canceled;
    switch (prepared.request.action) {
        .build => |request| {
            const program = try engine.construct(a, a, prepared.task, profile, prepared.catalog.bytes, request.proposal_json.bytes);
            if (cancellation) |flag| if (flag.load(.acquire)) return error.Canceled;
            const bytes = try contracts.encodeOwned(wire.Program, a, program);
            program_bytes.* = .{ .bytes = bytes };
            return .{ .built = work.reference(bytes) };
        },
        .run => |request| {
            const value = try engine.execute(a, a, cancellation, prepared.task, profile, prepared.catalog.bytes, prepared.program orelse return error.InvalidPreparedRequest, prepared.input orelse return error.InvalidPreparedRequest);
            return .{ .ran = .{ .program = try resources.parseReference(request.tool_ref.bytes), .input = prepared.input_ref orelse return error.InvalidPreparedRequest, .value = .{ .bytes = value } } };
        },
    }
}
fn encodeCapture(a: std.mem.Allocator, profile: []const u8, cancellation: ?*const std.atomic.Value(bool), bytes: []const u8, prepared: Prepared, comptime recovering: bool) ![]u8 {
    var program_bytes: ?contracts.Bytes(null) = null;
    var artifact: t.ToolArtifact = .{
        .task = prepared.task,
        .policy = prepared.policy,
        .call_id = prepared.request.call_id,
        .outcome = compute(a, profile, cancellation, prepared, &program_bytes) catch |err| blk: {
            // A new operational failure is not a rederived semantic result.
            if (recovering and (err == error.OutOfMemory or err == error.Capacity or err == error.Canceled)) return err;
            break :blk .{ .rejected = failure(if (prepared.request.action == .build) .construction else .execution, err) };
        },
        .model_text = .{ .bytes = "" },
    };
    const program = if (program_bytes) |encoded| (try contracts.decodeOwned(wire.Program, a, encoded.bytes)).value else null;
    artifact.model_text = render(a, artifact, program) catch |err| blk: {
        if (recovering and (err == error.OutOfMemory or err == error.Capacity)) return err;
        program_bytes = null;
        artifact.outcome = .{ .rejected = failure(.execution, err) };
        break :blk try render(a, artifact, null);
    };
    return contracts.encodeOwned(Captured, a, .{ .prepared = work.digest(bytes), .artifact = artifact, .program = program_bytes });
}
fn acquire(ctx: native.Context, bytes: []const u8) !native.registry.Acquisition {
    var decoded = try contracts.decodeOwned(Prepared, ctx.allocator, bytes);
    defer decoded.deinit();
    const prepared = decoded.value;
    if (!same(&prepared.policy, &work.digest(ctx.profile)) or !same(ctx.task_id, &std.fmt.bytesToHex(prepared.task, .lower))) return error.InvalidPreparedRequest;
    return .{ .captured = try encodeCapture(ctx.allocator, ctx.profile, ctx.cancellation, bytes, prepared, false) };
}
fn rederive(ctx: native.registry.RederivationContext, _: native.registry.RecoveryInput, _: []const u8, original: ?[]const u8) !native.registry.RederivationFinding {
    const bytes = original orelse return error.InvalidPreparedRequest;
    var decoded = try contracts.decodeOwned(Prepared, ctx.allocator, bytes);
    defer decoded.deinit();
    const prepared = decoded.value;
    if (!same(&prepared.task, &ctx.task) or !same(&prepared.policy, &work.digest(ctx.profile))) return error.InvalidPreparedRequest;
    return .{ .result = try encodeCapture(ctx.allocator, ctx.profile, ctx.cancellation, bytes, prepared, true) };
}

fn dependencies(a: std.mem.Allocator, objects: []const []const u8) ![]native.registry.Dependency {
    if (objects.len > 2) return error.InvalidProjection;
    var references: native.registry.ProjectionReferences = .{ .allocator = a };
    defer references.deinit();
    if (objects.len != 0) try references.object(t.ToolArtifact, t.model.ArtifactReference, objects[0], null);
    // Program embeds its image and interfaces. Its catalog digest binds policy;
    // it is not an object reference with an independently retained byte length.
    if (objects.len == 2) try references.object(wire.Program, t.model.ArtifactReference, objects[1], null);
    return references.finish();
}
fn interpret(ctx: native.registry.ProjectionContext, request: []const u8, prepared_bytes: []const u8, captured_bytes: []const u8) !native.registry.Projection {
    var prepared = try contracts.decodeOwned(Prepared, ctx.allocator, prepared_bytes);
    defer prepared.deinit();
    if (!same(prepared_bytes, if (prepared.value.request.action == .build) try prepareBuild(ctx, request) else try prepareRun(ctx, request))) return error.InvalidCapture;
    var captured = try contracts.decodeOwned(Captured, ctx.allocator, captured_bytes);
    defer captured.deinit();
    const result = captured.value;
    if (!same(&result.prepared, &work.digest(prepared_bytes)) or !same(&result.artifact.task, &ctx.task) or !same(&result.artifact.policy, &prepared.value.policy) or !same(result.artifact.call_id.bytes, prepared.value.request.call_id.bytes)) return error.InvalidCapture;
    var program: ?wire.Program = null;
    var evidence: ?t.GeneratedEvidenceReference = null;
    switch (result.artifact.outcome) {
        .built => |ref| {
            const bytes = (result.program orelse return error.InvalidCapture).bytes;
            if (prepared.value.request.action != .build or !resources.sameReference(work.reference(bytes), ref)) return error.InvalidCapture;
            program = (try contracts.decodeOwned(wire.Program, ctx.allocator, bytes)).value;
            const value = program.?;
            if (!same(&value.task, &ctx.task) or !same(&value.policy, &prepared.value.policy) or !same(&value.catalog, &work.digest(prepared.value.catalog.bytes)) or !same(value.recipe.bytes, prepared.value.request.action.build.proposal_json.bytes)) return error.InvalidCapture;
        },
        .ran => |value| {
            if (prepared.value.request.action != .run or result.program != null or !resources.sameReference(value.program, try resources.parseReference(prepared.value.request.action.run.tool_ref.bytes)) or !resources.sameReference(value.input, prepared.value.input_ref orelse return error.InvalidCapture)) return error.InvalidCapture;
        },
        .rejected => if (result.program != null) return error.InvalidCapture,
    }
    if (!same(result.artifact.model_text.bytes, (try render(ctx.allocator, result.artifact, program)).bytes)) return error.InvalidCapture;
    const artifact = try contracts.encodeOwned(t.ToolArtifact, ctx.allocator, result.artifact);
    const ref = work.reference(artifact);
    if (result.artifact.outcome == .ran) evidence = .{ .object = ref, .program = result.artifact.outcome.ran.program, .input = result.artifact.outcome.ran.input };
    const objects = try ctx.allocator.alloc([]const u8, if (result.program != null) 2 else 1);
    objects[0] = artifact;
    if (result.program) |value| objects[1] = try ctx.allocator.dupe(u8, value.bytes);
    return .{ .reply = try contracts.encodeOwned(t.ToolReply, ctx.allocator, .{ .artifact = ref, .program = if (result.artifact.outcome == .built) result.artifact.outcome.built else null, .evidence = evidence }), .objects = objects };
}
pub fn declaration(comptime build: bool) native.Declaration {
    return .{ .identity = if (build) t.tool_build_identity else t.tool_run_identity, .resource_role = if (build) "tool-construction" else "tool-execution", .kind = .leaf, .background = true, .public_outputs = true, .payload_schema = struct {
        fn schema(a: std.mem.Allocator) ![]u8 {
            return native.values.schemaBytes(t.ToolRequest, a);
        }
    }.schema, .resume_schema = struct {
        fn schema(a: std.mem.Allocator) ![]u8 {
            return native.values.schemaBytes(t.ToolReply, a);
        }
    }.schema, .capture = .{ .prepare = if (build) prepareBuild else prepareRun, .acquire = acquire, .interpret = interpret, .dependencies = dependencies }, .recovery = .{ .identity = "agent.recovery.pure-generated-tool.v1", .version = 1, .rederive = rederive } };
}
