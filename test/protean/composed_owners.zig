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
            const b = context.builder;
            const c = try a.Context.init(b);
            const integer = try c.scalar(u64);
            const unit = try c.scalar(void);
            const release_id = try context.external("composed/cleanup", try a.interop.schemaId(c, integer), try a.interop.schemaId(c, unit), if (write) .write else .read);
            const release = try a.interop.operation(c, release_id);
            const g = try generator.create(c, "composed/participant", integer, integer, integer, .{
                .captures = .{ .continuation = &.{integer} },
                .residual = &.{release},
                .parameters = &.{.{ .name = "input", .schema = integer }},
                .body_use = .reusable,
            });
            const joined = try generator.pipeline(c, "composed/pipeline", g, g);
            try context.registry.classify(try a.interop.operationId(c, g.effect()), .internal);
            try context.registry.classify(try a.interop.operationId(c, joined.generator.effect()), .internal);
            const body_type = try c.handledSchema(g.handler());
            const body_fn = try c.functionFor("participant", body_type);
            const body = try c.body(body_fn);
            const capability = try body.parameter("capability");
            const input = try body.parameter("input");
            const run_type = try c.callable(&.{}, integer, &.{g.effect()}, .{ .use = .reusable, .captures = &.{ g.capability(), integer } });
            const run_fn = try c.functionFor("participant offers", run_type);
            const run = try body.closureBody(run_fn);
            const reply = try run.performLocal(g.effect(), capability, input);
            try c.define(run_fn, try run.ret(try run.performLocal(g.effect(), capability, reply)));
            const cleanup_type = try c.callable(&.{.{ .name = "exit", .schema = try c.cleanupInfo(unit) }}, unit, &.{release}, .{ .use = .reusable, .captures = &.{integer} });
            const cleanup_fn = try c.functionFor("retained cleanup", cleanup_type);
            const cleanup = try body.closureBody(cleanup_fn);
            try c.define(cleanup_fn, try cleanup.ret(try cleanup.perform(release, input)));
            const cleanup_id = try a.interop.functionId(c, cleanup_fn);
            if (write) try context.registry.protectSite(cleanup_id, b.functions.items[@intCast(cleanup_id)].body.?, release_id);
            try c.define(body_fn, try body.ret(try body.protect(try body.lambda(run_fn, run_type), try body.lambda(cleanup_fn, cleanup_type), &.{})));
            const entry = try c.function("entry", &.{.{ .name = "args", .schema = unit }}, unit, &.{release});
            const root = try c.body(entry);
            var work = root;
            var stages: [3]Stage = undefined;
            var owners: [2]*const a.Value = undefined;
            for (&owners, 0..) |*owner, i| {
                const answer = try work.handleWithArguments(g.handler(), try work.lambda(body_fn, body_type), &.{.{ .name = "input", .value = try work.constant(u64, i + 1) }}, &.{});
                stages[i] = try Stage.open(work, answer, unit);
                owner.* = stages[i].package;
                work = stages[i].selected.body();
            }
            const answer = try work.call(joined.start, &.{ .{ .name = "left", .value = owners[0] }, .{ .name = "right", .value = owners[1] }, .{ .name = "input", .value = try work.constant(u64, 7) } });
            stages[2] = try Stage.open(work, answer, unit);
            work = stages[2].selected.body();
            _ = try work.disposePackage(stages[2].package);
            if (duplicate) _ = try work.disposePackage(stages[2].package);
            var result = try work.constant(void, {});
            var remaining = stages.len;
            while (remaining != 0) {
                remaining -= 1;
                result = try stages[remaining].finish(result);
            }
            try c.define(entry, try root.ret(result));
            if (assessment) try context.registry.speculate(try a.interop.functionId(c, entry), &.{release_id});
            return c.module(entry, unit);
        }
    };
}
const Stage = struct {
    parent: *a.Body,
    answer: *const a.Value,
    done: *const a.Case,
    selected: *const a.Case,
    package: *const a.Value,
    result: *const a.Schema,
    fn open(parent: *a.Body, answer: *const a.Value, result: *const a.Schema) !Stage {
        const done = try parent.caseOf(answer, "done");
        const selected = try parent.caseOf(answer, "yielded");
        const parts = try selected.body().destructure(selected.payload());
        return .{ .parent = parent, .answer = answer, .done = done, .selected = selected, .package = try parts.get("future"), .result = result };
    }
    fn finish(self: @This(), value: *const a.Value) !*const a.Value {
        return self.parent.match(self.answer, &.{ try self.done.fail(self.result, try self.done.body().constant(void, {})), try self.selected.ret(value) });
    }
};
fn compile(comptime duplicate: bool, comptime assessment: bool, comptime write: bool) !void {
    const System = protean.system(.{ .InitialArgs = void, .Result = void, .Failure = void, .application = Application(duplicate, assessment, write) });
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
