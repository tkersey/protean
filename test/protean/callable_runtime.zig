const std = @import("std");
const horos = @import("horos");
const protean = @import("protean");
const kronos = @import("kronos");
const witness = @import("callable.zig");

test "static-code callable preserves actual Kronos observations and branch work" {
    const allocator = std.testing.allocator;
    var prior_functions: ?usize = null;
    var prior_schemas: ?usize = null;
    for ([_]usize{ 1, 8, 64 }) |count| {
        var raw_builder = horos.source.Builder.init(allocator);
        defer raw_builder.deinit();
        var protean_builder = horos.source.Builder.init(allocator);
        defer protean_builder.deinit();
        var raw_registry = protean.admission.Registry.init(allocator);
        defer raw_registry.deinit();
        var protean_registry = protean.admission.Registry.init(allocator);
        defer protean_registry.deinit();
        const original = try witness.build(&raw_builder, &raw_registry, .interned, count);
        const changed = try witness.build(&protean_builder, &protean_registry, .static_code, count);
        try std.testing.expectError(error.SpeculativeEffect, protean.admission.verify(allocator, original, &raw_registry));
        try protean.admission.verify(allocator, changed, &protean_registry);
        var raw = try horos.program.compile(allocator, original);
        defer raw.deinit();
        var selected = try horos.program.compile(allocator, changed);
        defer selected.deinit();
        var raw_stats: kronos.Statistics = .{};
        var selected_stats: kronos.Statistics = .{};
        const invocation_image_0 = try allocator.alloc(u8, try horos.data.program_image.encodedLength(raw.program));
        defer allocator.free(invocation_image_0);
        _ = try horos.data.program_image.encode(allocator, raw.program, invocation_image_0);
        var before = observed: {
            const instance: horos.data.invocation.Instance = .{ .initial_args = &.{} };
            var session = switch (instance) {
                .initial_args => |args| try kronos.Session.initImage(allocator, invocation_image_0, args),
                .state => |state| try kronos.Session.restoreImage(allocator, invocation_image_0, state),
            };
            defer session.deinit();
            session.statistics = &raw_stats;
            session.store.statistics = &raw_stats.storage;
            _ = try kronos.invocation.advance(&session, .none, null);
            break :observed try kronos.invocation.finish(allocator, &session, true);
        };
        defer before.deinit();
        const invocation_image_1 = try allocator.alloc(u8, try horos.data.program_image.encodedLength(selected.program));
        defer allocator.free(invocation_image_1);
        _ = try horos.data.program_image.encode(allocator, selected.program, invocation_image_1);
        var after = observed: {
            const instance: horos.data.invocation.Instance = .{ .initial_args = &.{} };
            var session = switch (instance) {
                .initial_args => |args| try kronos.Session.initImage(allocator, invocation_image_1, args),
                .state => |state| try kronos.Session.restoreImage(allocator, invocation_image_1, state),
            };
            defer session.deinit();
            session.statistics = &selected_stats;
            session.store.statistics = &selected_stats.storage;
            _ = try kronos.invocation.advance(&session, .none, null);
            break :observed try kronos.invocation.finish(allocator, &session, true);
        };
        defer after.deinit();
        try std.testing.expect(before.record == .completed);
        try std.testing.expect(after.record == .completed);
        try std.testing.expectEqualSlices(u8, &.{}, before.record.completed);
        try std.testing.expectEqualSlices(u8, before.record.completed, after.record.completed);
        try std.testing.expectEqual(count, selected_stats.multi_templates);
        try std.testing.expectEqual(count * 2, selected_stats.branch_activations);
        try std.testing.expectEqual(raw_stats.transitions, selected_stats.transitions);
        try std.testing.expectEqual(raw_stats.multi_templates, selected_stats.multi_templates);
        try std.testing.expectEqual(raw_stats.branch_activations, selected_stats.branch_activations);
        if (prior_functions) |expected| try std.testing.expectEqual(expected, selected.program.functions.len);
        if (prior_schemas) |expected| try std.testing.expectEqual(expected, selected.program.schemas.len);
        prior_functions = selected.program.functions.len;
        prior_schemas = selected.program.schemas.len;
        std.debug.print("callable installs={d} original_bytes={d} selected_bytes={d} " ++
            "functions={d} schemas={d} transitions={d} templates={d} branches={d}\n", .{
            count,                                                        try horos.data.program_image.encodedLength(raw.program),
            try horos.data.program_image.encodedLength(selected.program), selected.program.functions.len,
            selected.program.schemas.len,                                 selected_stats.transitions,
            selected_stats.multi_templates,                               selected_stats.branch_activations,
        });
    }
}
