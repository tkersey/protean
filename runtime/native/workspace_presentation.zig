const std = @import("std");
const contracts = @import("protean_contracts");
const registry = @import("registry.zig");
const state = @import("state.zig");
const workspace = @import("workspace_state.zig");
const storage = @import("store.zig");
const proposal = @import("projection_proposal.zig");
const dynamic = @import("dynamic_values.zig");
const json = @import("json.zig");
const values = @import("values.zig");
const wp = @import("workspace_projection.zig");
const wc = contracts.workspace;

pub const Target = union(enum) {
    controller: struct { protected_identity: state.Digest, model_profile: state.Digest },
    model: struct {
        work: state.Digest,
        port: state.Digest,
        generation: u64,
        model_profile: state.Digest,
    },
};
pub const Rendered = struct { view: ?state.Reference = null, text: ?[]u8 = null };

pub fn render(
    ctx: registry.ProjectionContext,
    reference: wc.Ref,
    target: Target,
    maximum: ?u64,
) !Rendered {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var scoped = ctx;
    scoped.allocator = arena.allocator();
    const result = try renderIn(scoped, reference, target, maximum);
    return .{
        .view = result.view,
        .text = if (result.text) |text| try ctx.allocator.dupe(u8, text) else null,
    };
}

fn renderIn(
    ctx: registry.ProjectionContext,
    reference: wc.Ref,
    target: Target,
    maximum: ?u64,
) !Rendered {
    var view = (try ctx.objects.workspaceView(ctx.allocator, reference)) orelse return .{};
    defer view.deinit();
    var remaining = maximum;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(ctx.allocator);
    try text.appendSlice(ctx.allocator, "{\"selected_context_data\":[");
    if (view.value.description.projection) |selected| {
        if (view.value.description.values.items.len != 0) return error.InvalidProjection;
        try renderProjection(ctx, selected, target, &remaining, &text);
    } else {
        for (view.value.description.values.items, 0..) |ref, index| {
            if (index != 0) try text.append(ctx.allocator, ',');
            const block = try renderValue(ctx, ref, null, &remaining);
            defer ctx.allocator.free(block);
            try text.appendSlice(ctx.allocator, block);
        }
    }
    try text.appendSlice(ctx.allocator, "]}");
    if (maximum) |limit| if (text.items.len > limit) return error.Capacity;
    return .{ .view = view.value.artifact, .text = try text.toOwnedSlice(ctx.allocator) };
}

fn read(ctx: registry.ProjectionContext, ref: state.Reference) ![]u8 {
    const bytes = try ctx.object(ref, std.math.cast(usize, ref.bytes) orelse return error.Capacity);
    errdefer ctx.allocator.free(bytes);
    if (bytes.len != ref.bytes or !std.meta.eql(storage.digest(bytes), ref.digest))
        return error.InvalidProjection;
    return bytes;
}

fn open(
    comptime T: type,
    ctx: registry.ProjectionContext,
    ref: state.Reference,
) !contracts.Decoded(T) {
    const bytes = try read(ctx, ref);
    defer ctx.allocator.free(bytes);
    return contracts.decodeOwned(T, ctx.allocator, bytes);
}

fn renderProjection(
    ctx: registry.ProjectionContext,
    selected: workspace.ProjectionSelection,
    target: Target,
    remaining: *?u64,
    text: *std.ArrayList(u8),
) !void {
    const a = ctx.allocator;
    var value = try open(workspace.ValueArtifact, ctx, selected.result);
    defer value.deinit();
    const schema = try read(ctx, value.value.schema);
    defer a.free(schema);
    const bytes = try read(ctx, value.value.value);
    defer a.free(bytes);
    var decoded = try proposal.decodeResult(a, schema, bytes);
    defer decoded.deinit();
    try requireBinding(ctx, selected, decoded.header.consumer, target);
    var index: usize = 0;
    for (decoded.header.blocks.items, 0..) |block, position| {
        if (position != 0) try text.append(a, ',');
        const rendered = switch (block) {
            .computed => try renderComputed(ctx, selected.result, decoded, remaining),
            .explanation => |explanation| try renderExplanation(a, explanation, remaining),
            .value, .source => blk: {
                if (index >= selected.values.items.len) return error.InvalidProjection;
                const ref = selected.values.items[index];
                const declared = if (block == .value) block.value else block.source.value;
                if (!std.meta.eql(ref.digest, try wp.identity(declared, .value)))
                    return error.InvalidProjection;
                index += 1;
                break :blk try renderValue(
                    ctx,
                    ref,
                    if (block == .source) block.source else null,
                    remaining,
                );
            },
        };
        defer a.free(rendered);
        try text.appendSlice(a, rendered);
    }
    if (index != selected.values.items.len) return error.InvalidProjection;
}

fn requireBinding(
    ctx: registry.ProjectionContext,
    selected: workspace.ProjectionSelection,
    reference: wc.Ref,
    target: Target,
) !void {
    var saved = try open(workspace.ReplyObservation, ctx, selected.observation);
    defer saved.deinit();
    if (!std.meta.eql(saved.value.id, try wp.identity(reference, .observation)))
        return error.InvalidConsumer;
    try ctx.objects.requireConsumer(ctx.allocator, saved.value);
    const observed = saved.value.evidence.read.consumer;
    switch (target) {
        .controller => |actual| {
            if (observed.selection.target != .controller or
                !std.meta.eql(actual.protected_identity, observed.interface.protected_identity) or
                !std.meta.eql(actual.model_profile, observed.interface.model_profile))
                return error.StaleConsumer;
            if (ctx.controller) |controller| {
                if (!std.meta.eql(observed.controller.binding, controller.binding) or
                    observed.controller.epoch != controller.epoch) return error.StaleConsumer;
            }
        },
        .model => |actual| {
            if (observed.selection.target != .model) return error.ConsumerMismatch;
            const declared = observed.selection.target.model;
            const model = observed.model orelse return error.InvalidConsumer;
            if (!std.meta.eql(actual.work, try wp.identity(declared.expected.work, .work)) or
                !std.meta.eql(actual.port, try wp.identity(declared.port, .port)) or
                actual.generation != declared.generation or
                !std.meta.eql(
                    actual.model_profile,
                    model.profile_digest,
                )) return error.StaleConsumer;
        },
    }
}

fn consume(a: std.mem.Allocator, value: json.Value, remaining: *?u64) ![]u8 {
    const bytes = try json.canonicalOptional(a, value, remaining.*);
    if (remaining.*) |maximum| remaining.* = maximum - bytes.len;
    return bytes;
}

fn renderComputed(
    ctx: registry.ProjectionContext,
    result: state.Reference,
    decoded: proposal.Envelope(wc.ProjectionProposal),
    remaining: *?u64,
) ![]u8 {
    const a = ctx.allocator;
    var budget = remaining.*;
    var payload = try dynamic.decodeWithin(a, decoded.payload_schema, decoded.payload, &budget);
    defer payload.deinit();
    var item = json.object();
    try json.put(a, &item, "kind", json.string("computed"));
    try json.put(
        a,
        &item,
        "result",
        try values.toJson(wc.Ref, a, try wp.reference(a, .value, result.digest)),
    );
    try json.put(
        a,
        &item,
        "schema_identity",
        json.string(try a.dupe(
            u8,
            &std.fmt.bytesToHex(storage.digest(decoded.payload_schema), .lower),
        )),
    );
    try json.put(a, &item, "schema", try wp.schema(a, decoded.payload_schema));
    try json.put(a, &item, "value", payload.value);
    return consume(a, item, remaining);
}

fn renderExplanation(a: std.mem.Allocator, text: contracts.Utf8, remaining: *?u64) ![]u8 {
    var item = json.object();
    try json.put(a, &item, "kind", json.string("authored_explanation"));
    try json.put(a, &item, "text", json.string(text.bytes));
    return consume(a, item, remaining);
}

fn renderValue(
    ctx: registry.ProjectionContext,
    ref: state.Reference,
    slice: ?@FieldType(wc.PresentationBlock, "source"),
    remaining: *?u64,
) ![]u8 {
    const a = ctx.allocator;
    var value = try open(workspace.ValueArtifact, ctx, ref);
    defer value.deinit();
    var origin = try open(workspace.Derivation, ctx, value.value.provenance);
    defer origin.deinit();
    const schema = try read(ctx, value.value.schema);
    defer a.free(schema);
    const bytes = try read(ctx, value.value.value);
    defer a.free(bytes);
    var item = json.object();
    try json.put(a, &item, "kind", json.string(@tagName(origin.value.kind)));
    try json.put(
        a,
        &item,
        "value_reference",
        try values.toJson(wc.Ref, a, try wp.reference(a, .value, ref.digest)),
    );
    try json.put(a, &item, "schema", try wp.schema(a, schema));
    try json.put(
        a,
        &item,
        "provenance",
        try values.toJson(
            wc.Ref,
            a,
            try wp.reference(a, .provenance, value.value.provenance.digest),
        ),
    );
    if (slice) |range| {
        var text = try contracts.decodeOwned(contracts.Utf8, a, bytes);
        defer text.deinit();
        const expected = try values.schemaBytes(contracts.Utf8, a);
        defer a.free(expected);
        if (origin.value.kind != .acquisition or !std.mem.eql(u8, schema, expected) or
            range.offset > text.value.bytes.len or
            range.length > text.value.bytes.len - range.offset)
            return error.InvalidSourceSlice;
        const selected = text.value.bytes[@intCast(range.offset)..][0..@intCast(range.length)];
        if (!std.unicode.utf8ValidateSlice(selected)) return error.InvalidSourceSlice;
        try json.put(a, &item, "slice", try values.toJson(@TypeOf(range), a, range));
        try json.put(a, &item, "value", json.string(selected));
        return consume(a, item, remaining);
    }
    var budget = remaining.*;
    var payload = try dynamic.decodeWithin(a, schema, bytes, &budget);
    defer payload.deinit();
    try json.put(a, &item, "value", payload.value);
    return consume(a, item, remaining);
}
