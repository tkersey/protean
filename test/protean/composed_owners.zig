//! Protean admission traverses cleanup retained by a composed exchange owner.
const std = @import("std");
const protean = @import("protean");
const horos = @import("horos");
const source = horos.source;
const a = horos.authoring;
const generator = horos.library.generator;
fn Application(comptime duplicate: bool, comptime assessment: bool, comptime write: bool) type {
    return struct {
        pub fn emit(context: protean.Context) !source.Module {
            const c = context.author;
            const integer = try c.schema(u64);
            const unit = try c.schema(void);
            const release = try context.external(
                "composed/cleanup",
                integer,
                unit,
                if (write) .write else .read,
            );
            const g = try generator.create(c, "composed/participant", integer, integer, integer, .{
                .captures = .{ .continuation = .{integer} },
                .residual = &.{release},
                .parameters = .{ .input = integer },
                .body_use = .reusable,
            });
            const joined = try generator.pipeline(c, "composed/pipeline", g, g);
            try context.registry.classify(try a.interop.operationId(c, g.effect()), .internal);
            try context.registry.classify(
                try a.interop.operationId(c, joined.generator.effect()),
                .internal,
            );
            const body_type = try c.handledSchema(g.handler());
            const body_fn = try c.functionFor("participant", body_type);
            const body = try c.body(body_fn);
            try defineParticipant(context, g, body_fn, body, integer, unit, release);
            const entry = try c.function("entry", .{ .args = unit }, unit, &.{release});
            const root = try c.body(entry);
            const result = try consumeParticipants(root, g, joined, body_fn, body_type, unit);
            try c.define(entry, try root.ret(result));
            if (assessment) try context.registry.speculate(try a.interop.functionId(
                c,
                entry,
            ), &.{try a.interop.operationId(c, release)});
            return c.module(entry, unit);
        }
        fn consumeParticipants(
            root: anytype,
            g: anytype,
            joined: anytype,
            body_fn: anytype,
            body_type: anytype,
            unit: anytype,
        ) !*const a.Value(a.Shape(void)) {
            const first_answer = try root.handleWithArguments(g.handler(), try root.lambda(
                body_fn,
                body_type,
            ), .{ .input = try root.constant(u64, 1) }, .{});
            const first = try Stage(@TypeOf(root), @TypeOf(first_answer)).open(
                root,
                first_answer,
                unit,
            );
            const second_body = first.selected.body();
            const second_answer = try second_body.handleWithArguments(
                g.handler(),
                try second_body.lambda(body_fn, body_type),
                .{ .input = try second_body.constant(u64, 2) },
                .{},
            );
            const second = try Stage(@TypeOf(second_body), @TypeOf(second_answer)).open(
                second_body,
                second_answer,
                unit,
            );
            const join_body = second.selected.body();
            const joined_answer = try join_body.call(joined.start, .{
                .left = first.package,
                .right = second.package,
                .input = try join_body.constant(u64, 7),
            });
            const last = try Stage(@TypeOf(join_body), @TypeOf(joined_answer)).open(
                join_body,
                joined_answer,
                unit,
            );
            const work = last.selected.body();
            _ = try work.disposePackage(last.package);
            if (duplicate) _ = try work.disposePackage(last.package);
            return first.finish(
                try second.finish(try last.finish(try work.constant(void, {}))),
            );
        }
        fn defineParticipant(
            context: protean.Context,
            g: anytype,
            body_fn: anytype,
            body: anytype,
            integer: anytype,
            unit: anytype,
            release: anytype,
        ) !void {
            const b = context.builder;
            const c = context.author;
            const release_id = try a.interop.operationId(c, release);
            const capability = try body.parameter("capability");
            const input = try body.parameter("input");
            const run_type = try c.callable(.{}, integer, &.{
                g.effect(),
            }, .{ .use = .reusable, .captures = .{ g.capability(), integer } });
            const run_fn = try c.functionFor("participant offers", run_type);
            const run = try body.closureBody(run_fn);
            const reply = try run.performLocal(g.effect(), capability, input);
            try c.define(run_fn, try run.ret(try run.performLocal(g.effect(), capability, reply)));
            const cleanup_type = try c.callable(.{
                .exit = try c.cleanupInfo(unit),
            }, unit, &.{release}, .{ .use = .reusable, .captures = &.{integer} });
            const cleanup_fn = try c.functionFor("retained cleanup", cleanup_type);
            const cleanup = try body.closureBody(cleanup_fn);
            try c.define(cleanup_fn, try cleanup.ret(try cleanup.perform(release, input)));
            const cleanup_id = try a.interop.functionId(c, cleanup_fn);
            if (write) try context.registry.protectSite(
                cleanup_id,
                b.functions.items[@intCast(cleanup_id)].body.?,
                release_id,
            );
            try c.define(
                body_fn,
                try body.ret(
                    try body.protect(
                        try body.lambda(run_fn, run_type),
                        try body.lambda(cleanup_fn, cleanup_type),
                        .{},
                    ),
                ),
            );
        }
    };
}
fn Stage(comptime Parent: type, comptime Answer: type) type {
    const Done = @typeInfo(
        @TypeOf(@as(Parent, undefined).caseOf(@as(Answer, undefined), "done")),
    ).error_union.payload;
    const Selected = @typeInfo(
        @TypeOf(@as(Parent, undefined).caseOf(@as(Answer, undefined), "yielded")),
    ).error_union.payload;
    const Package = @typeInfo(
        @TypeOf(
            @as(Selected, undefined).body().field(@as(Selected, undefined).payload(), "future"),
        ),
    ).error_union.payload;
    return struct {
        parent: Parent,
        answer: Answer,
        done: Done,
        selected: Selected,
        package: Package,
        result: *const a.Schema(a.Shape(void)),
        fn open(parent: Parent, answer: Answer, result: *const a.Schema(a.Shape(void))) !@This() {
            const done = try parent.caseOf(answer, "done");
            const selected = try parent.caseOf(answer, "yielded");
            const parts = try selected.body().destructure(selected.payload());
            return .{
                .parent = parent,
                .answer = answer,
                .done = done,
                .selected = selected,
                .package = try parts.get("future"),
                .result = result,
            };
        }
        fn finish(
            self: @This(),
            value: *const a.Value(a.Shape(void)),
        ) !*const a.Value(a.Shape(void)) {
            return self.parent.match(self.answer, .{
                .done = try self.done.fail(self.result, try self.done.body().constant(void, {})),
                .yielded = try self.selected.ret(value),
            });
        }
    };
}
fn compile(comptime duplicate: bool, comptime assessment: bool, comptime write: bool) !void {
    const System = protean.system(.{
        .InitialArgs = void,
        .Result = void,
        .Failure = void,
        .application = Application(duplicate, assessment, write),
    });
    var result = try protean.compile(std.testing.allocator, System);
    defer result.deinit();
}
test "normal Protean entry admits composed owners and their read cleanup" {
    try compile(false, false, false);
    try compile(false, true, false);
}
test "composed ownership cannot be consumed twice" {
    try std.testing.expectError(error.UnavailableSlot, compile(true, false, false));
}
test "assessment cannot launder write authority through retained cleanup" {
    try compile(false, false, true);
    try std.testing.expectError(error.SpeculativeEffect, compile(false, true, true));
}
