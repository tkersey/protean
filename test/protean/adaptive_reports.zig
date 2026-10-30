const std = @import("std");
const horos = @import("horos");
const protean = @import("protean");
const kosmos = @import("kosmos");
const report = @import("adaptive_report");
const t = @import("adaptive_types");
const contracts = protean.contracts;

test "authored report validation preserves multi-citation support and exact rejection positions" {
    const a = std.testing.allocator;
    const image = try reportImage(a);
    defer a.free(image);
    for (expected, 0..) |rejection, scenario| {
        var claims = supported;
        var input: report.Input = .{
            .report = .{ .summary = .{
                .bytes = "Structural support is present.",
            }, .claims = .{ .items = &claims }, .limitations = .{ .items = &.{.{
                .bytes = "Membership does not prove entailment.",
            }} } },
            .evidence_count = 3,
        };
        switch (scenario) {
            0 => {},
            1 => input.report.claims.items = &.{},
            2 => input.report.summary.bytes = "",
            3 => claims[1].statement.bytes = "",
            4 => claims[1].reasoning.bytes = "",
            5 => claims[2].reasoning.bytes = "",
            6 => claims[0].evidence_indices.items = &.{},
            7 => claims[1].evidence_indices.items = &.{},
            8 => claims[0].evidence_indices.items = &.{ 0, 3 },
            9 => claims[1].evidence_indices.items = &.{ 1, 2, 1 },
            10 => input.report.claims.items = claims[2..],
            11 => input.evidence_count = 0,
            else => unreachable,
        }
        const args = try contracts.encodeOwned(report.Input, a, input);
        defer a.free(args);
        var output = try kosmos.invocation.invoke(a, .{ .image = image, .instance = .{
            .initial_args = args,
        } });
        defer output.deinit();
        try std.testing.expect(output.record == .completed);
        var decoded = try contracts.decodeOwned(?t.ReportRejection, a, output.record.completed);
        defer decoded.deinit();
        try std.testing.expectEqualDeep(rejection, decoded.value);
        const canonical = try contracts.encodeOwned(?t.ReportRejection, a, decoded.value);
        defer a.free(canonical);
        try std.testing.expectEqualSlices(u8, output.record.completed, canonical);
    }
}

test "report model arguments decode nested records and exact numeric citations strictly" {
    const native = @import("protean_native");
    const model = protean.model_invocation;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Model = protean.model(
        .{ .name = "report-codec", .model = "fixture", .parameters = .{}, .protocol = struct {
            pub const semantic_identity = model.protocol_identity;
        } },
    );
    var invocation = try t.P.templateValue(Model, .{ .items = &.{} }, .{
        .minimum_calls = 1,
        .maximum_calls = 1,
        .parallel_calls = false,
    });
    invocation.tools = t.P.allDeclarations();
    for (cases) |case| {
        const bytes = try std.json.Stringify.valueAlloc(a, .{.{
            .type = "function_call",
            .status = "completed",
            .call_id = "report",
            .name = "report",
            .arguments = case.arguments,
        }}, .{});
        const parsed = try native.json.parse(a, bytes, .{
            .bytes = bytes.len,
            .tokens = bytes.len,
        });
        const normalized = try native.responses.OutputNormalizer(t.P).normalize(
            a,
            invocation,
            parsed.value,
        );
        const decoded = normalized.output.items.items[0].function_call.decoded_action;
        if (case.failure) |failure| {
            try std.testing.expectEqual(failure, decoded.invalid);
        } else {
            try std.testing.expectEqualSlices(
                u64,
                &.{ 0, std.math.maxInt(u64) },
                decoded.decoded.report.claims.items[0].evidence_indices.items,
            );
            try std.testing.expectEqualStrings(
                "Unchecked paths",
                decoded.decoded.report.limitations.items[0].bytes,
            );
            const encoded = try contracts.encodeOwned(t.Report, a, decoded.decoded.report);
            var restored = try contracts.decodeOwned(t.Report, a, encoded);
            defer restored.deinit();
            try std.testing.expectEqualDeep(decoded.decoded.report, restored.value);
        }
    }
    try checkReportSchema(a);
}

const supported = [_]t.Claim{
    .{ .kind = .observation, .statement = .{
        .bytes = "Both acquired ranges contain guards.",
    }, .reasoning = .{ .bytes = "" }, .evidence_indices = .{ .items = &.{ 0, 1 } } },
    .{ .kind = .inference, .statement = .{
        .bytes = "The guards constrain these paths.",
    }, .reasoning = .{
        .bytes = "The observed branches reject before mutation.",
    }, .evidence_indices = .{ .items = &.{ 1, 2 } } },
    .{ .kind = .hypothesis, .statement = .{
        .bytes = "Another path may bypass the guard.",
    }, .reasoning = .{
        .bytes = "Other callers have not been inspected.",
    }, .evidence_indices = .{ .items = &.{} } },
};
const Expected = ?t.ReportRejection;
const expected = [_]Expected{
    null,
    .{ .reason = .empty_report, .claim_index = null, .evidence_position = null },
    .{ .reason = .empty_summary, .claim_index = null, .evidence_position = null },
    .{ .reason = .empty_statement, .claim_index = 1, .evidence_position = null },
    .{ .reason = .missing_reasoning, .claim_index = 1, .evidence_position = null },
    .{ .reason = .missing_reasoning, .claim_index = 2, .evidence_position = null },
    .{ .reason = .missing_evidence, .claim_index = 0, .evidence_position = null },
    .{ .reason = .missing_evidence, .claim_index = 1, .evidence_position = null },
    .{ .reason = .out_of_range, .claim_index = 0, .evidence_position = 1 },
    .{ .reason = .duplicate_evidence, .claim_index = 1, .evidence_position = 2 },
    .{ .reason = .missing_evidence, .claim_index = null, .evidence_position = null },
    .{ .reason = .out_of_range, .claim_index = 0, .evidence_position = 0 },
};

fn reportImage(a: std.mem.Allocator) ![]u8 {
    var builder = horos.source.Builder.init(a);
    defer builder.deinit();
    var registry = protean.admission.Registry.init(builder.allocator());
    defer registry.deinit();
    const c = try protean.Context.init(&builder, &registry);
    const entry = try report.define(c);
    const module = try c.author.module(entry, try c.schema(t.Failure));
    try protean.admission.verify(a, module, &registry);
    var compiled = try horos.program.compile(a, module);
    defer compiled.deinit();
    const image = try a.alloc(u8, try horos.data.program_image.encodedLength(compiled.program));
    errdefer a.free(image);
    _ = try compiled.encode(a, image);
    return image;
}

const Case = struct {
    arguments: []const u8,
    failure: ?@FieldType(t.P.DecodedAnswer, "invalid"),
};
const cases = [_]Case{
    .{
        .arguments =
        \\{"summary":"Report","claims":[{"kind":"inference","statement":"Claim","reasoning":"Reason","evidence_indices":[0,18446744073709551615]}],"limitations":["Unchecked paths"]}
        ,
        .failure = null,
    },
    .{
        .arguments =
        \\{"summary":"Report","claims":[{"kind":"observation","statement":"Claim","reasoning":"","evidence_indices":[],"foreign_task":"other"}],"limitations":[]}
        ,
        .failure = .unknown_field,
    },
    .{
        .arguments =
        \\{"summary":"Report","claims":[{"kind":"observation","statement":"Claim","reasoning":""}],"limitations":[]}
        ,
        .failure = .missing_field,
    },
    .{
        .arguments =
        \\{"summary":"Report","claims":{},"limitations":[]}
        ,
        .failure = .wrong_type,
    },
    .{
        .arguments =
        \\{"summary":"Report","claims":[{"kind":"observation","statement":"A","statement":"B","reasoning":"","evidence_indices":[]}],"limitations":[]}
        ,
        .failure = .duplicate_field,
    },
    .{
        .arguments =
        \\{"summary":"Report","claims":[{"kind":"observation","statement":"Claim","reasoning":"","evidence_indices":[-1]}],"limitations":[]}
        ,
        .failure = .wrong_type,
    },
    .{
        .arguments =
        \\{"summary":"Report","claims":[{"kind":"observation","statement":"Claim","reasoning":"","evidence_indices":["0"]}],"limitations":[]}
        ,
        .failure = .wrong_type,
    },
};

fn checkReportSchema(a: std.mem.Allocator) !void {
    const native = @import("protean_native");
    const declaration = t.P.allDeclarations().items[t.ordinal("report")];
    const schema = (try native.json.parse(a, declaration.input_schema_json.bytes, .{})).value;
    const properties = native.json.get(schema, "properties").?;
    const claims_schema = native.json.get(properties, "claims").?;
    try std.testing.expectEqualStrings("array", (native.json.get(claims_schema, "type").?).string);
    try std.testing.expect(native.json.get(claims_schema, "maxItems") == null);
    const claim_schema = native.json.get(claims_schema, "items").?;
    try std.testing.expect(!(native.json.get(claim_schema, "additionalProperties").?).bool);
    const nodes = declaration.argument_codec.items;
    try std.testing.expectEqual(.sequence, nodes[1].field.kind);
    try std.testing.expectEqual(@as(u32, 1), nodes[1].children);
    try std.testing.expectEqual(.product, nodes[2].field.kind);
    try std.testing.expectEqual(@as(u32, 4), nodes[2].children);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, nodes[3].field.enum_tags.items);
}
