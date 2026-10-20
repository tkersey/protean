//! Shared authored inputs for independent workspace execution and controller traces.
const source = @import("horos").source;

pub fn controller(b: *source.Builder, indexed: bool) !source.Module {
    const c = @import("protean_contracts");
    const anchor = try c.schema(struct { task: [16]u8 }, b);
    const unit = try b.scalar(void);
    const number = try b.scalar(u64);
    const private = if (indexed) try b.schema(.{ .product = &.{ number, number } }) else number;
    const input = try b.schema(.{ .product = &.{ anchor, private } });
    const payload = try b.schema(.{ .product = &.{ number, private } });
    const reply = try c.schema(c.controller.Reply(u64), b);
    const deliberate = try b.effect(.{ .identity = "controller/1/deliberate", .payload = payload, .result = reply, .external = false });
    const entry = try b.declare(&.{input}, number, &.{deliberate}, &.{});
    const state = try b.primitive(private, .field, &.{try b.reference(b.parameter(entry, 0))}, 1);
    const proposal = if (indexed) try b.primitive(number, .field, &.{state}, 0) else state;
    const request = try b.primitive(payload, .product, &.{ proposal, state }, 0);
    const result = try b.variable(reply);
    const response = try b.primitive(number, .field, &.{try b.reference(result)}, 0);
    try b.define(entry, try b.bind(result, try b.term(.{ .perform = .{ .effect = deliberate, .payload = request } }), try b.pure(response)));
    return b.module(entry, unit);
}

pub fn retainedHandlers(b: *source.Builder, shallow: bool) !source.Module {
    const original = if (shallow) try source.examples.shallowResumptions(b) else try source.examples.successorState(b);
    // These fixtures supply every capability explicitly. Making their effects
    // internal permits source ingestion without changing attachment identity.
    for (b.effects.items) |*effect| effect.external = false;
    const function = b.functions.items[@intCast(original.entry)];
    const root = try b.declare(&.{try b.scalar(void)}, function.result, function.effects, function.regions);
    try b.define(root, try b.term(.{ .call = .{ .function = original.entry, .arguments = &.{} } }));
    return b.module(root, original.failure);
}

pub fn yieldingDisposal(b: *source.Builder) !source.Module {
    return disposal(b, true);
}

pub fn yieldingCancellation(b: *source.Builder) !source.Module {
    return disposal(b, false);
}

fn disposal(b: *source.Builder, request: bool) !source.Module {
    const unit = try b.scalar(void);
    const u = try b.scalar(u64);
    const info = try @import("horos").library.cleanup.exitInfo(b, unit);
    const observed = try b.effect(.{ .identity = "example/disposal", .payload = info, .result = unit, .external = false });
    const body = try b.declare(&.{}, u, &.{}, &.{});
    try b.define(body, try b.term(.{ .yield_then = try b.pure(try b.constant(u64, 42)) }));
    const cleanup = try b.declare(&.{info}, unit, &.{observed}, &.{});
    const requested = try b.term(.{ .perform = .{ .effect = observed, .payload = try b.reference(b.parameter(cleanup, 0)) } });
    const finished = try b.term(.{ .yield_then = try b.pure(try b.constant(void, {})) });
    try b.define(cleanup, try b.term(.{ .yield_then = if (request) try b.bind(try b.variable(unit), requested, finished) else try b.pure(try b.constant(void, {})) }));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{}, .result = u } } });
    const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{info}, .result = unit, .effects = &.{observed} } } });
    const entry = try b.declare(&.{unit}, u, &.{observed}, &.{});
    try b.define(entry, try b.term(.{ .protect = .{ .body = try b.lambda(body, body_type), .cleanup = try b.lambda(cleanup, cleanup_type) } }));
    return b.module(entry, unit);
}

pub fn distinctAttachments(b: *source.Builder) !source.Module {
    const unit = try b.scalar(void);
    const u = try b.scalar(u64);
    const effect = try b.effect(.{ .identity = "example/attachments", .payload = unit, .result = u, .external = false });
    const cap = try b.schema(.{ .internal = .{ .capability = effect } });
    const returns = try b.declare(&.{u}, u, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    var handlers: [2]source.Id = undefined;
    for (&handlers, [_]u64{ 42, 99 }) |*handler, answer| {
        const token = try b.schema(.{ .internal = .{ .resumption = .{ .effect = effect, .input = u, .answer = u, .handled = &.{effect}, .effects = &.{effect}, .capture_bound = &.{ unit, u, cap }, .mode = .deep, .use = .linear } } });
        const clause = try b.declare(&.{ unit, token }, u, &.{effect}, &.{});
        try b.define(clause, try b.term(.{ .resume_value = .{ .resumption = try b.reference(b.parameter(clause, 1)), .argument = try b.constant(u64, answer) } }));
        handler.* = try b.handler(.{ .mode = .deep, .input = u, .answer = u, .effects = &.{effect}, .return_function = returns, .clauses = &.{.{ .effect = effect, .function = clause, .resumption = token }} });
    }
    const body = try b.declare(&.{ cap, cap }, u, &.{effect}, &.{});
    try b.define(body, try b.term(.{ .perform = .{ .effect = effect, .capability = try b.reference(b.parameter(body, 1)), .payload = try b.constant(void, {}) } }));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{ cap, cap }, .result = u, .effects = &.{effect} } } });
    const outer = try b.declare(&.{cap}, u, &.{effect}, &.{});
    try b.define(outer, try b.term(.{ .handle = .{ .handler = handlers[1], .body = try b.lambda(body, body_type), .arguments = &.{try b.reference(b.parameter(outer, 0))} } }));
    const outer_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{cap}, .result = u, .effects = &.{effect} } } });
    const main = try b.declare(&.{unit}, u, &.{effect}, &.{});
    try b.define(main, try b.term(.{ .handle = .{ .handler = handlers[0], .body = try b.lambda(outer, outer_type) } }));
    return b.module(main, unit);
}

pub fn binaryQuestion(b: *source.Builder) !source.Module {
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const ask = try b.effect(.{ .identity = "example/binary-question", .payload = unit, .result = boolean, .external = false });
    const entry = try b.declare(&.{unit}, boolean, &.{ask}, &.{});
    try b.define(entry, try b.term(.{ .perform = .{ .effect = ask, .payload = try b.constant(void, {}) } }));
    return b.module(entry, unit);
}

pub fn mutableAlternatives(b: *source.Builder) !source.Module {
    const u = try b.scalar(u64);
    const unit = try b.scalar(void);
    const prefix = try b.effect(.{ .identity = "example/prefix", .payload = u, .result = unit, .external = false });
    const ask = try b.effect(.{ .identity = "example/alternative", .payload = unit, .result = u, .external = false, .control_use = .multi });
    const r = b.region();
    const region = try b.schema(.{ .internal = .{ .region = r } });
    const cell = try b.schema(.{ .internal = .{ .cell = .{ .element = u, .region = r } } });
    const main = try b.declare(&.{u}, u, &.{ prefix, ask }, &.{});
    const inside = try b.declare(&.{ region, u }, u, &.{ prefix, ask }, &.{r});
    const allocated = try b.variable(cell);
    const alias = try b.variable(cell);
    const answer = try b.variable(u);
    const fault = try b.failureLiteral(try b.constant(void, {}));
    const initial = try b.value(.{ .schema = u, .expression = .{ .primitive = .{ .opcode = .integer_add, .operands = &.{ try b.reference(b.parameter(inside, 1)), try b.constant(u64, 1) }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }} } } });
    const before = try b.primitive(u, .cell_get, &.{try b.reference(alias)}, 0);
    const sum = try b.value(.{ .schema = u, .expression = .{ .primitive = .{ .opcode = .integer_add, .operands = &.{ before, try b.reference(answer) }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }} } } });
    const write = try b.primitive(unit, .cell_set, &.{ try b.reference(allocated), sum }, 0);
    const result = try b.pure(try b.primitive(u, .cell_get, &.{try b.reference(alias)}, 0));
    const update = try b.bind(try b.variable(unit), try b.pure(write), result);
    const choice = try b.bind(answer, try b.term(.{ .perform = .{ .effect = ask, .payload = try b.constant(void, {}) } }), update);
    const emitted = try b.bind(try b.variable(unit), try b.term(.{ .perform = .{ .effect = prefix, .payload = initial } }), choice);
    const aliased = try b.bind(alias, try b.pure(try b.reference(allocated)), emitted);
    try b.define(inside, try b.bind(allocated, try b.pure(try b.primitive(cell, .cell_new, &.{ try b.reference(b.parameter(inside, 0)), initial }, 0)), aliased));
    const body = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{ region, u }, .result = u, .effects = &.{ prefix, ask }, .regions = &.{r} } } });
    try b.define(main, try b.term(.{ .with_region = .{ .region = r, .body = try b.lambda(inside, body), .arguments = &.{try b.reference(b.parameter(main, 0))} } }));
    return b.module(main, unit);
}

pub fn exclusiveAlternative(b: *source.Builder) !source.Module {
    const u = try b.scalar(u64);
    const unit = try b.scalar(void);
    const resource = try b.resource(u);
    const ask = try b.effect(.{ .identity = "example/exclusive", .payload = unit, .result = unit, .external = false, .control_use = .multi });
    const factory = try b.declare(&.{}, resource, &.{}, &.{});
    const consume = try b.declare(&.{resource}, u, &.{}, &.{});
    try b.resourceAuthority(resource, &.{factory}, &.{consume});
    try b.define(factory, try b.pure(try b.primitive(resource, .resource_pack, &.{try b.constant(u64, 42)}, 0)));
    try b.define(consume, try b.pure(try b.primitive(u, .resource_unpack, &.{try b.reference(b.parameter(consume, 0))}, 0)));
    const main = try b.declare(&.{unit}, u, &.{ask}, &.{});
    const owned = try b.variable(resource);
    const result = try b.term(.{ .call = .{ .function = consume, .arguments = &.{try b.reference(owned)} } });
    const pause = try b.bind(try b.variable(unit), try b.term(.{ .perform = .{ .effect = ask, .payload = try b.constant(void, {}) } }), result);
    try b.define(main, try b.bind(owned, try b.term(.{ .call = .{ .function = factory, .arguments = &.{} } }), pause));
    return b.module(main, unit);
}

pub fn gcd(b: *source.Builder) !source.Module {
    const u = try b.scalar(u64);
    const unit = try b.scalar(void);
    const pair = try b.schema(.{ .product = &.{ u, u } });
    const recur = try b.declare(&.{ u, u }, u, &.{}, &.{});
    const entry = try b.declare(&.{pair}, u, &.{}, &.{});
    const x = try b.reference(b.parameter(recur, 0));
    const y = try b.reference(b.parameter(recur, 1));
    const zero = try b.constant(u64, 0);
    const condition = try b.primitive(try b.scalar(bool), .equal, &.{ y, zero }, 0);
    const fault = try b.failureLiteral(try b.constant(void, {}));
    const rem = try b.value(.{ .schema = u, .expression = .{ .primitive = .{ .opcode = .integer_rem, .operands = &.{ x, y }, .failures = &.{
        .{ .kind = .arithmetic_overflow, .value = fault }, .{ .kind = .division_by_zero, .value = fault },
    } } } });
    const done = try b.pure(x);
    const again = try b.term(.{ .call = .{ .function = recur, .arguments = &.{ y, rem } } });
    try b.define(recur, try b.term(.{ .conditional = .{ .condition = condition, .when_true = done, .when_false = again } }));
    const left = try b.variable(u);
    const right = try b.variable(u);
    const run = try b.term(.{ .call = .{ .function = recur, .arguments = &.{ try b.reference(left), try b.reference(right) } } });
    try b.define(entry, try b.term(.{ .unpack_product = .{ .value = try b.reference(b.parameter(entry, 0)), .variables = &.{ left, right }, .body = run } }));
    return b.module(entry, unit);
}

pub fn listLength(b: *source.Builder) !source.Module {
    return listLengthWithYields(b, true);
}

pub fn listLengthWithYields(b: *source.Builder, yields: bool) !source.Module {
    const u = try b.scalar(u64);
    const unit = try b.scalar(void);
    const list = try b.reserveSchema();
    const cons = try b.schema(.{ .product = &.{ u, list } });
    try b.defineSchema(list, .{ .sum = &.{ unit, cons } });
    const recurse = try b.declare(&.{list}, u, &.{}, &.{});
    const empty = try b.variable(unit);
    const nonempty = try b.variable(cons);
    const head = try b.variable(u);
    const tail = try b.variable(list);
    const length = try b.variable(u);
    const fault = try b.failureLiteral(try b.constant(void, {}));
    const incremented = try b.value(.{ .schema = u, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ try b.reference(length), try b.constant(u64, 1) },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }},
    } } });
    const call = try b.term(.{ .call = .{ .function = recurse, .arguments = &.{try b.reference(tail)} } });
    const joined = try b.bind(length, call, try b.pure(incremented));
    const yielded = if (yields) try b.term(.{ .yield_then = joined }) else joined;
    const unpack = try b.term(.{ .unpack_product = .{ .value = try b.reference(nonempty), .variables = &.{ head, tail }, .body = yielded } });
    const done = try b.pure(try b.constant(u64, 0));
    try b.define(recurse, try b.term(.{ .match_sum = .{ .value = try b.reference(b.parameter(recurse, 0)), .cases = &.{
        .{ .variable = empty, .body = done }, .{ .variable = nonempty, .body = unpack },
    } } }));
    return b.module(recurse, unit);
}

pub fn alternatives(b: *source.Builder, multi: bool) !source.Module {
    const u = try b.scalar(u64);
    const unit = try b.scalar(void);
    const emitted = try b.effect(.{ .identity = "example/prefix", .payload = u, .result = unit, .external = false });
    const ask = try b.effect(.{ .identity = "example/alternative", .payload = unit, .result = u, .external = false, .control_use = if (multi) .multi else .linear });
    const entry = try b.declare(&.{u}, u, &.{ emitted, ask }, &.{});
    const prefix_value = try b.variable(u);
    const ignored = try b.variable(unit);
    const answer = try b.variable(u);
    const fault = try b.failureLiteral(try b.constant(void, {}));
    const prefix = try b.value(.{ .schema = u, .expression = .{ .primitive = .{ .opcode = .integer_add, .operands = &.{ try b.reference(b.parameter(entry, 0)), try b.constant(u64, 1) }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }} } } });
    const result = try b.value(.{ .schema = u, .expression = .{ .primitive = .{ .opcode = .integer_add, .operands = &.{ try b.reference(prefix_value), try b.reference(answer) }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }} } } });
    const branch = try b.bind(answer, try b.term(.{ .perform = .{ .effect = ask, .payload = try b.constant(void, {}) } }), try b.pure(result));
    const emit = try b.bind(ignored, try b.term(.{ .perform = .{ .effect = emitted, .payload = try b.reference(prefix_value) } }), branch);
    try b.define(entry, try b.bind(prefix_value, try b.pure(prefix), emit));
    return b.module(entry, unit);
}

pub const Reconstruction = struct {
    const c = @import("protean_contracts");
    const data = @import("horos_data");
    const Id = source.Id;
    pub const Input = c.Vector(u64, null);
    pub const Output = struct { total: u64, covered: u64, instruction_cut: u64 };
    pub const Direct = struct { records: Input, position: u64, total: u64, covered: u64, instruction_cut: u64, revisit: bool };
    pub const Indexed = struct { records: Input, index: Input, cursor: u64, total: u64, covered: u64, instruction_cut: u64, exceptional: u64 };
    pub const Private = union(enum) { initial: Input, @"resume": Direct };
    pub const Proposal = struct { position: u64, value: u64, total: u64, covered: u64, indexed: bool, instruction_cut: u64 };
    pub const Response = union(enum) { next: void, adopt: c.workspace.Adoption };
    pub const Types = struct {
        pub const application_id = "reconstruction-fixture";
        pub const input_schema_id = "reconstruction.input/1";
        pub const output_schema_id = "reconstruction.output/1";
        pub const failure_schema_id = "reconstruction.failure/1";
        pub const message_schema_id = "reconstruction.message/1";
        pub const Input = Reconstruction.Input;
        pub const Output = Reconstruction.Output;
        pub const Failure = void;
        pub const Message = c.Utf8;
        pub const Answer = void;
        pub const ControllerInput = struct { anchor: c.controller.TaskAnchor, private: Private };
    };
    const E = struct {
        b: *source.Builder,
        fn schema(e: E, comptime T: type) !Id {
            return c.schema(T, e.b);
        }
        fn field(e: E, comptime T: type, value: Id, index: u64) !Id {
            return e.b.primitive(try e.schema(T), .field, &.{value}, index);
        }
        fn product(e: E, comptime T: type, fields: []const Id) !Id {
            return e.b.primitive(try e.schema(T), .product, fields, 0);
        }
        fn number(e: E, value: u64) !Id {
            return e.b.constant(u64, value);
        }
        fn arithmetic(e: E, opcode: data.program.Opcode, left: Id, right: Id) !Id {
            return e.b.value(.{ .schema = try e.schema(u64), .expression = .{ .primitive = .{ .opcode = opcode, .operands = &.{ left, right }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = try e.b.failureLiteral(try e.b.constant(void, {})) }} } } });
        }
        fn get(e: E, list: Id, index: Id) !Id {
            const optional = try e.b.schema(.{ .sum = &.{ try e.schema(void), try e.schema(u64) } });
            const found = try e.b.primitive(optional, .sequence_get, &.{ list, index }, 0);
            return e.b.value(.{ .schema = try e.schema(u64), .expression = .{ .primitive = .{ .opcode = .variant_payload, .operands = &.{found}, .immediate = 1, .failures = &.{.{ .kind = .invalid_variant, .value = try e.b.failureLiteral(try e.b.constant(void, {})) }} } } });
        }
        fn length(e: E, list: Id) !Id {
            return e.b.primitive(try e.schema(u64), .sequence_length, &.{list}, 0);
        }
        fn choose(e: E, condition: Id, yes: Id, no: Id) !Id {
            return e.b.term(.{ .conditional = .{ .condition = condition, .when_true = yes, .when_false = no } });
        }
        fn call(e: E, function: Id, arguments: []const Id) !Id {
            return e.b.term(.{ .call = .{ .function = function, .arguments = arguments } });
        }
        fn result(e: E, state: Id, indexed: bool) !Id {
            return e.b.pure(try e.product(Output, &.{ try e.field(u64, state, if (indexed) 3 else 2), try e.field(u64, state, if (indexed) 4 else 3), try e.field(u64, state, if (indexed) 5 else 4) }));
        }
    };
    pub fn controller(b: *source.Builder, indexed: bool, cleanup: bool) !source.Module {
        return controllerWithCleanup(b, indexed, cleanup, null);
    }
    pub fn controllerWithCleanup(b: *source.Builder, indexed: bool, cleanup: bool, workspace_command: ?c.workspace.Command) !source.Module {
        const e: E = .{ .b = b };
        const unit = try e.schema(void);
        const state_schema = if (indexed) try e.schema(Indexed) else try e.schema(Direct);
        const private = if (indexed) state_schema else try e.schema(Private);
        const input = try b.schema(.{ .product = &.{ try e.schema(c.controller.TaskAnchor), private } });
        const payload = try b.schema(.{ .product = &.{ try e.schema(Proposal), state_schema } });
        const reply = try e.schema(c.controller.Reply(Response));
        const deliberate = try b.effect(.{ .identity = "controller/1/deliberate", .payload = payload, .result = reply, .external = false });
        const loop = try b.declare(&.{state_schema}, try e.schema(Output), &.{deliberate}, &.{});
        const state = try b.reference(b.parameter(loop, 0));
        const records = try e.field(Input, state, 0);
        const position = try e.field(u64, state, if (indexed) 2 else 1);
        const selected = if (indexed) try e.get(try e.field(Input, state, 1), position) else position;
        const item = try e.get(records, selected);
        const total = try e.field(u64, state, if (indexed) 3 else 2);
        const covered = try e.field(u64, state, if (indexed) 4 else 3);
        const cut = try e.field(u64, state, if (indexed) 5 else 4);
        const next_position = try e.arithmetic(.integer_add, position, try e.number(1));
        const next_total = try e.arithmetic(.integer_add, total, item);
        const next_covered = try e.arithmetic(.integer_add, covered, try e.number(1));
        const response = try b.variable(reply);
        const next_state = try b.variable(state_schema);
        const next = try b.reference(next_state);
        if (indexed) {
            const exceptional = try b.variable(try e.schema(u64));
            const is_exceptional = try b.primitive(try e.schema(bool), .less, &.{ try e.number(100), item }, 0);
            const updated = try e.product(Indexed, &.{ records, try e.field(Input, state, 1), next_position, next_total, next_covered, cut, try b.reference(exceptional) });
            const step = try b.bind(exceptional, try e.choose(is_exceptional, try b.pure(selected), try b.pure(try e.field(u64, state, 6))), try e.call(loop, &.{updated}));
            const proposal = try e.product(Proposal, &.{ try e.field(u64, state, 6), try e.get(records, try e.field(u64, state, 6)), total, covered, try b.constant(bool, true), cut });
            const done = try b.bind(response, try b.term(.{ .perform = .{ .effect = deliberate, .payload = try b.primitive(payload, .product, &.{ proposal, state }, 0) } }), try e.result(state, true));
            try b.define(loop, try e.choose(try b.primitive(try e.schema(bool), .less, &.{ position, try e.length(try e.field(Input, state, 1)) }, 0), step, done));
        } else {
            const ordinary = try e.product(Direct, &.{ records, next_position, next_total, next_covered, cut, try b.constant(bool, false) });
            const revisited = try e.product(Direct, &.{ records, try e.length(records), total, covered, cut, try b.constant(bool, false) });
            const proposal = try e.product(Proposal, &.{ selected, item, try e.field(u64, next, 2), try e.field(u64, next, 3), try b.constant(bool, false), cut });
            const interact = try b.bind(response, try b.term(.{ .perform = .{ .effect = deliberate, .payload = try b.primitive(payload, .product, &.{ proposal, next }, 0) } }), try e.call(loop, &.{next}));
            const step = try b.bind(next_state, try e.choose(try e.field(bool, state, 5), try b.pure(revisited), try b.pure(ordinary)), interact);
            try b.define(loop, try e.choose(try b.primitive(try e.schema(bool), .less, &.{ position, try e.length(records) }, 0), step, try e.result(state, false)));
        }
        const body = try b.declare(&.{input}, try e.schema(Output), &.{deliberate}, &.{});
        const value = if (indexed) try e.field(Indexed, try b.reference(b.parameter(body, 0)), 1) else try e.field(Private, try b.reference(b.parameter(body, 0)), 1);
        if (indexed) {
            try b.define(body, try e.call(loop, &.{value}));
        } else {
            const original = try b.variable(try e.schema(Input));
            const resumed = try b.variable(state_schema);
            const initial = try e.product(Direct, &.{ try b.reference(original), try e.number(0), try e.number(0), try e.number(0), try e.number(1), try b.constant(bool, false) });
            try b.define(body, try b.term(.{ .match_sum = .{ .value = value, .cases = &.{ .{ .variable = original, .body = try e.call(loop, &.{initial}) }, .{ .variable = resumed, .body = try e.call(loop, &.{try b.reference(resumed)}) } } } }));
        }
        if (!cleanup) return b.module(body, unit);
        const info = try @import("horos").library.cleanup.exitInfo(b, unit);
        const dispose = try b.effect(.{ .identity = "controller/1/snapshot", .payload = try e.schema(u64), .result = unit, .external = false });
        const workspace_effect = if (workspace_command != null) try b.effect(.{ .identity = "controller/1/workspace", .payload = try e.schema(c.workspace.Command), .result = try e.schema(c.workspace.Reply), .external = false }) else null;
        const cleanup_effects = if (workspace_effect) |effect| try b.allocator().dupe(@TypeOf(dispose), &.{ dispose, effect }) else &.{dispose};
        const unwind = try b.declare(&.{info}, unit, cleanup_effects, &.{});
        const disposed = try b.term(.{ .perform = .{ .effect = dispose, .payload = try e.number(7) } });
        try b.define(unwind, if (workspace_effect) |effect| try b.bind(try b.variable(try e.schema(c.workspace.Reply)), try b.term(.{ .perform = .{ .effect = effect, .payload = try b.literal(.{ .schema = try e.schema(c.workspace.Command), .bytes = try c.encodeOwned(c.workspace.Command, b.allocator(), workspace_command.?) }) } }), disposed) else disposed);
        const body_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{input}, .result = try e.schema(Output), .effects = &.{deliberate} } } });
        const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{info}, .result = unit, .effects = cleanup_effects } } });
        const effects = if (workspace_effect) |effect| try b.allocator().dupe(@TypeOf(dispose), &.{ deliberate, dispose, effect }) else &.{ deliberate, dispose };
        const entry = try b.declare(&.{input}, try e.schema(Output), effects, &.{});
        try b.define(entry, try b.term(.{ .protect = .{ .body = try b.lambda(body, body_type), .cleanup = try b.lambda(unwind, cleanup_type), .arguments = &.{try b.reference(b.parameter(entry, 0))} } }));
        return b.module(entry, unit);
    }
    pub fn converter(b: *source.Builder, to_indexed: bool, variant: enum { valid, fail, diverge }) !source.Module {
        const e: E = .{ .b = b };
        const carry = if (to_indexed) try e.schema(Direct) else try e.schema(Indexed);
        const result = if (to_indexed) try e.schema(Indexed) else try e.schema(Private);
        const input = try b.schema(.{ .product = &.{ carry, try e.schema(c.controller.OwnerView) } });
        const entry = try b.declare(&.{input}, result, &.{}, &.{});
        if (variant == .fail) {
            try b.define(entry, try b.term(.{ .fail = try b.constant(void, {}) }));
        } else if (variant == .diverge) {
            try b.define(entry, try e.call(entry, &.{try b.reference(b.parameter(entry, 0))}));
        } else {
            const argument = try b.reference(b.parameter(entry, 0));
            const state = if (to_indexed) try e.field(Direct, argument, 0) else try e.field(Indexed, argument, 0);
            const view = try e.field(c.controller.OwnerView, argument, 1);
            const cut = try e.field(u64, view, 2);
            const records = try e.field(Input, state, 0);
            if (to_indexed) {
                const index = try b.declare(&.{ try e.schema(u64), try e.schema(u64), try e.schema(Input) }, try e.schema(Input), &.{}, &.{});
                const cursor = try b.reference(b.parameter(index, 0));
                const end = try b.reference(b.parameter(index, 1));
                const prior = try b.reference(b.parameter(index, 2));
                const previous = try e.arithmetic(.integer_sub, cursor, try e.number(1));
                const appended = try b.primitive(try e.schema(Input), .sequence_append, &.{ prior, previous }, 0);
                try b.define(index, try e.choose(try b.primitive(try e.schema(bool), .less, &.{ end, cursor }, 0), try e.call(index, &.{ previous, end, appended }), try b.pure(prior)));
                const indexes = try b.variable(try e.schema(Input));
                const built = try e.product(Indexed, &.{ records, try b.reference(indexes), try e.number(0), try e.field(u64, state, 2), try e.field(u64, state, 3), cut, try e.number(0) });
                try b.define(entry, try b.bind(indexes, try e.call(index, &.{ try e.length(records), try e.field(u64, state, 1), try b.primitive(try e.schema(Input), .sequence, &.{}, 0) }), try b.pure(built)));
            } else {
                const direct = try e.product(Direct, &.{ records, try e.field(u64, state, 6), try e.field(u64, state, 3), try e.field(u64, state, 4), cut, try b.constant(bool, true) });
                try b.define(entry, try b.pure(try b.primitive(result, .variant, &.{direct}, 1)));
            }
        }
        return b.module(entry, try e.schema(void));
    }
};
