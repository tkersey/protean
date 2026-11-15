const std = @import("std");
const horos = @import("horos");
const protean = @import("protean");
const Id = horos.source.Id;
const allocator = std.testing.allocator;
const Request = protean.notification.Request(u64, [16]u8, protean.contracts.Utf8);
const Input = union(enum) { observe: u64, delivery: Request, cancel: void, preview: Request };
const Result = union(enum) { ordinary: void, delivery: bool };
const Dispatcher = protean.notification.Dispatcher(Input, Result);

const Fixture = struct {
    builder: horos.source.Builder,
    registry: protean.admission.Registry,
    entry: Id,
    failure: Id,

    fn init() !Fixture {
        var b = horos.source.Builder.init(allocator);
        errdefer b.deinit();
        var registry = protean.admission.Registry.init(allocator);
        errdefer registry.deinit();
        const c = try protean.Context.init(&b, &registry);
        const input = try horos.authoring.interop.schemaId(c.author, try c.schema(Input));
        const result = try horos.authoring.interop.schemaId(c.author, try c.schema(Result));
        const failure = try b.scalar(void);
        const ordinary = try b.declare(&.{input}, result, &.{}, &.{});
        try b.define(ordinary, try b.pure(try b.primitive(
            result,
            .variant,
            &.{try b.constant(void, {})},
            0,
        )));
        const entry = try Dispatcher.emit(c, "owner-dm", ordinary);
        return .{ .builder = b, .registry = registry, .entry = entry, .failure = failure };
    }

    fn deinit(self: *Fixture) void {
        self.registry.deinit();
        self.builder.deinit();
    }

    fn check(self: *Fixture) !void {
        try protean.admission.verify(
            allocator,
            self.builder.module(self.entry, self.failure),
            &self.registry,
        );
    }

    fn expectRejected(self: *Fixture) !void {
        var compiled = try horos.program.compile(allocator, self.builder.module(
            self.entry,
            self.failure,
        ));
        defer compiled.deinit();
        try std.testing.expectError(error.InvalidNotificationEntry, self.check());
    }

    fn replacementRequest(self: *Fixture) !Id {
        const c = try protean.Context.init(&self.builder, &self.registry);
        return horos.authoring.interop.valueId(c.author, try c.literal(Request, .{
            .destination = 55,
            .key = @splat(9),
            .payload = .{ .bytes = "changed after construction" },
        }));
    }
};

test "notification dispatcher admits one input-bound delivery branch" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.check();
    var compiled = try horos.program.compile(allocator, f.builder.module(f.entry, f.failure));
    defer compiled.deinit();
    const b = &f.builder;
    const root = b.terms.items[@intCast(b.functions.items[@intCast(f.entry)].body.?)].match_sum;
    try std.testing.expectEqual(4, root.cases.len);
    const write = b.terms.items[@intCast(root.cases[1].body)].bind.value;
    const operation = b.terms.items[@intCast(write)].perform;
    const payload = b.values.items[@intCast(operation.payload)];
    try std.testing.expectEqual(root.cases[1].variable, payload.expression.variable);
    try std.testing.expectEqual(.write, f.registry.roleOf(operation.effect));
    try std.testing.expectEqual(1, f.registry.sites.items.len);
}

test "notification rejects an unregistered raw perform of the checked effect" {
    var f = try Fixture.init();
    defer f.deinit();
    const b = &f.builder;
    const effect_id = f.registry.sites.items[0].target;
    const effect = b.effects.items[@intCast(effect_id)];
    const raw = try b.declare(&.{effect.payload}, effect.result, &.{effect_id}, &.{});
    const request = try b.reference(b.functions.items[@intCast(raw)].parameters[0]);
    try b.define(raw, try b.term(.{ .perform = .{
        .effect = effect_id,
        .payload = request,
    } }));
    try std.testing.expectError(error.ProtectedEffectBypass, f.check());
}

test "notification dispatcher cannot be called or selected as a helper entry" {
    for ([_]bool{ false, true }) |replace_entry| {
        var f = try Fixture.init();
        defer f.deinit();
        const b = &f.builder;
        const original = b.functions.items[@intCast(f.entry)];
        const helper = try b.declare(
            &.{b.variables.items[@intCast(original.parameters[0])]},
            original.result,
            original.effects,
            &.{},
        );
        const argument = try b.reference(b.functions.items[@intCast(helper)].parameters[0]);
        try b.define(helper, try b.term(.{ .call = .{
            .function = f.entry,
            .arguments = &.{argument},
        } }));
        if (replace_entry) f.entry = helper;
        try std.testing.expectError(error.InvalidNotificationEntry, f.check());
    }
}

test "notification write cannot be speculated or reclassified" {
    var f = try Fixture.init();
    defer f.deinit();
    const effect = f.registry.sites.items[0].target;
    try std.testing.expectError(error.EffectRoleMismatch, f.registry.classify(effect, .read));
    try f.registry.speculate(f.entry, &.{effect});
    try std.testing.expectError(error.SpeculativeEffect, f.check());
}

test "notification entry cannot escape through a lambda or handler callback" {
    for ([_]bool{ false, true }) |handler_callback| {
        var f = try Fixture.init();
        defer f.deinit();
        const b = &f.builder;
        const entry = b.functions.items[@intCast(f.entry)];
        const input = b.variables.items[@intCast(entry.parameters[0])];
        if (handler_callback) {
            _ = try b.handler(.{
                .mode = .deep,
                .input = input,
                .answer = entry.result,
                .return_function = f.entry,
                .clauses = &.{},
            });
        } else {
            const shape = try b.schema(.{ .internal = .{ .computation = .{
                .parameters = &.{input},
                .result = entry.result,
                .effects = entry.effects,
            } } });
            _ = try b.lambda(f.entry, shape);
        }
        try std.testing.expectError(error.InvalidNotificationEntry, f.check());
    }
}

test "notification identity reservation rejects a raw read without a construction" {
    var f = try Fixture.init();
    defer f.deinit();
    const effect = try f.builder.effect(.{
        .identity = "agent.notification.deliver.v2.raw",
        .payload = f.failure,
        .result = f.failure,
        .external = true,
    });
    try f.registry.classify(effect, .read);
    try std.testing.expectError(error.EffectRoleMismatch, f.check());
}

test "notification admission refuses a rewritten checked payload" {
    for ([_]bool{ false, true }) |preserve_value_id| {
        var f = try Fixture.init();
        defer f.deinit();
        const b = &f.builder;
        const root = b.functions.items[@intCast(f.entry)].body.?;
        const dispatch = b.terms.items[@intCast(root)].match_sum;
        const write = b.terms.items[@intCast(dispatch.cases[1].body)].bind.value;
        const other = try f.replacementRequest();
        if (preserve_value_id) {
            const payload = b.terms.items[@intCast(write)].perform.payload;
            b.values.items[@intCast(payload)] = b.values.items[@intCast(other)];
        } else b.terms.items[@intCast(write)].perform.payload = other;
        try f.expectRejected();
    }
}

test "notification admission refuses a fabricated delivery discriminator" {
    var f = try Fixture.init();
    defer f.deinit();
    const b = &f.builder;
    const root = b.functions.items[@intCast(f.entry)].body.?;
    const input = b.variables.items[@intCast(b.functions.items[@intCast(f.entry)].parameters[0])];
    const request = try f.replacementRequest();
    const replacement = try b.primitive(input, .variant, &.{request}, 1);
    b.terms.items[@intCast(root)].match_sum.value = replacement;
    try f.expectRejected();
}

test "notification admission preserves the delivery ordinal among same-schema variants" {
    var f = try Fixture.init();
    defer f.deinit();
    const b = &f.builder;
    const root = b.functions.items[@intCast(f.entry)].body.?;
    const cases = try b.allocator().dupe(
        std.meta.Elem(@FieldType(@FieldType(horos.source.ast.Term, "match_sum"), "cases")),
        b.terms.items[@intCast(root)].match_sum.cases,
    );
    std.mem.swap(@TypeOf(cases[0]), &cases[1], &cases[3]);
    b.terms.items[@intCast(root)].match_sum.cases = cases;
    try f.expectRejected();
}

test "notification admission refuses repeating the registered perform node" {
    var f = try Fixture.init();
    defer f.deinit();
    const b = &f.builder;
    const dispatch = b.terms.items[@intCast(b.functions.items[@intCast(f.entry)].body.?)].match_sum;
    const body = dispatch.cases[1].body;
    const bind = b.terms.items[@intCast(body)].bind;
    const reply = try b.variable(b.variables.items[@intCast(bind.variable)]);
    const again = try b.bind(reply, bind.value, bind.next);
    b.terms.items[@intCast(body)].bind.next = again;
    try std.testing.expectError(error.InvalidNotificationEntry, f.check());
}

test "notification admission refuses replacing the returned delivery reply" {
    for ([_]bool{ false, true }) |change_variant| {
        var f = try Fixture.init();
        defer f.deinit();
        const b = &f.builder;
        const function = b.functions.items[@intCast(f.entry)];
        const dispatch = b.terms.items[@intCast(function.body.?)].match_sum;
        const next = b.terms.items[@intCast(dispatch.cases[1].body)].bind.next;
        const result = if (change_variant)
            try b.primitive(function.result, .variant, &.{try b.constant(void, {})}, 0)
        else
            try b.primitive(function.result, .variant, &.{try b.constant(bool, false)}, 1);
        b.terms.items[@intCast(next)] = .{ .value = result };
        try f.expectRejected();
    }
}

test "notification admission retains the selected effect identity bytes" {
    for ([_]bool{ false, true }) |replace_bytes| {
        var f = try Fixture.init();
        defer f.deinit();
        const id = f.registry.entry_dispatches.items[0].effect;
        const effect = &f.builder.effects.items[@intCast(id)];
        if (replace_bytes) {
            const identity = @constCast(effect.identity);
            identity[identity.len - 1] = 'x';
        } else effect.identity = "agent.notification.deliver.v1.changed";
        try f.expectRejected();
    }
}

test "notification admission preserves ordinary input delegation and permits ordinary body edits" {
    for ([_]bool{ false, true }) |change_input| {
        var f = try Fixture.init();
        defer f.deinit();
        const b = &f.builder;
        const entry = f.registry.entry_dispatches.items[0];
        if (change_input) {
            const root = b.terms.items[@intCast(entry.body)].match_sum;
            const c = try protean.Context.init(b, &f.registry);
            const input = try horos.authoring.interop.valueId(
                c.author,
                try c.literal(Input, .{ .cancel = {} }),
            );
            const arguments = try b.allocator().dupe(Id, &.{input});
            b.terms.items[@intCast(root.cases[0].body)].call.arguments = arguments;
            try f.expectRejected();
        } else {
            const body = b.functions.items[@intCast(entry.ordinary)].body.?;
            const successor = try b.term(.{ .yield_then = body });
            b.functions.items[@intCast(entry.ordinary)].body = successor;
            try f.check();
            var compiled = try horos.program.compile(allocator, b.module(f.entry, f.failure));
            defer compiled.deinit();
        }
    }
}

test "notification admission rejects malformed dispatch bounds and added operation controls" {
    const Mutation = enum {
        functions,
        parameter,
        ordinary_parameter,
        input_schema,
        result_schema,
        scrutinee,
        case_count,
        case_variable,
        case_body,
        bind_value,
        bind_next,
        reply_variable,
        payload,
        value_schema,
        capability,
        bodies,
        use_site,
        control_use,
        returned,
    };
    for (std.enums.values(Mutation)) |mutation| {
        var f = try Fixture.init();
        defer f.deinit();
        const b = &f.builder;
        const entry = f.registry.entry_dispatches.items[0];
        const function = b.functions.items[@intCast(entry.function)];
        const root = &b.terms.items[@intCast(entry.body)].match_sum;
        const body = &b.terms.items[@intCast(root.cases[1].body)].bind;
        const write = &b.terms.items[@intCast(body.value)].perform;
        const invalid = std.math.maxInt(Id);
        switch (mutation) {
            .functions => b.functions.items.len = @intCast(entry.function),
            .parameter => b.functions.items[@intCast(entry.function)].parameters = &.{invalid},
            .ordinary_parameter => {
                b.functions.items[@intCast(entry.ordinary)].parameters = &.{invalid};
            },
            .input_schema => b.schemas.items[
                @intCast(b.variables.items[
                    @intCast(function.parameters[0])
                ])
            ] = .unit,
            .result_schema => b.schemas.items[@intCast(function.result)] = .unit,
            .scrutinee => root.value = invalid,
            .case_count => root.cases = root.cases[0..2],
            .case_variable => @constCast(root.cases)[1].variable = invalid,
            .case_body => @constCast(root.cases)[1].body = invalid,
            .bind_value => body.value = invalid,
            .bind_next => body.next = invalid,
            .reply_variable => body.variable = invalid,
            .payload => write.payload = invalid,
            .value_schema => b.values.items[@intCast(write.payload)].schema = invalid,
            .capability => write.capability = write.payload,
            .bodies => write.bodies = &.{invalid},
            .use_site => write.use_site_capabilities = &.{invalid},
            .control_use => b.effects.items[@intCast(entry.effect)].control_use = .multi,
            .returned => b.terms.items[@intCast(body.next)].value = invalid,
        }
        const expected = if (mutation == .functions)
            error.InvalidSource
        else
            error.InvalidNotificationEntry;
        try std.testing.expectError(expected, f.check());
    }
}

fn allocationFailureFixture(a: std.mem.Allocator) !void {
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    var registry = protean.admission.Registry.init(a);
    defer registry.deinit();
    const c = try protean.Context.init(&b, &registry);
    const input = try horos.authoring.interop.schemaId(c.author, try c.schema(Input));
    const result = try horos.authoring.interop.schemaId(c.author, try c.schema(Result));
    const ordinary = try b.declare(&.{input}, result, &.{}, &.{});
    try b.define(ordinary, try b.pure(try b.primitive(
        result,
        .variant,
        &.{try b.constant(void, {})},
        0,
    )));
    _ = try Dispatcher.emit(c, "owner-dm", ordinary);
}

test "notification construction releases partial allocations" {
    try std.testing.checkAllAllocationFailures(allocator, allocationFailureFixture, .{});
}
