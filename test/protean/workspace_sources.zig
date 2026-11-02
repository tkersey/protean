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
    const deliberate = try b.effect(.{
        .identity = "controller/1/deliberate",
        .payload = payload,
        .result = reply,
        .external = false,
    });
    const entry = try b.declare(&.{input}, number, &.{deliberate}, &.{});
    const state = try b.primitive(private, .field, &.{try b.reference(b.parameter(entry, 0))}, 1);
    const proposal = if (indexed) try b.primitive(number, .field, &.{state}, 0) else state;
    const request = try b.primitive(payload, .product, &.{ proposal, state }, 0);
    const result = try b.variable(reply);
    const response = try b.primitive(number, .field, &.{try b.reference(result)}, 0);
    try b.define(
        entry,
        try b.bind(
            result,
            try b.term(.{ .perform = .{ .effect = deliberate, .payload = request } }),
            try b.pure(response),
        ),
    );
    return b.module(entry, unit);
}

pub fn controllerWithHandler(b: *source.Builder, shallow: bool) !source.Module {
    const original = try controller(b, false);
    const function = b.functions.items[@intCast(original.entry)];
    const input = b.variables.items[@intCast(function.parameters[0])];
    const number = function.result;
    const unit = original.failure;
    const deliberate = function.effects[0];
    const local = try b.effect(.{
        .identity = "example/controller-local",
        .payload = unit,
        .result = unit,
        .external = false,
    });
    const capability = try b.schema(.{ .internal = .{ .capability = local } });
    const mode: @import("horos_data").program.Mode = if (shallow) .shallow else .deep;
    const token = try b.schema(.{ .internal = .{ .resumption = .{
        .effect = local,
        .input = unit,
        .answer = number,
        .effects = &.{deliberate},
        .escaping = if (shallow) &.{deliberate} else &.{},
        .handled = &.{local},
        .capture_bound = &.{ unit, number, input, capability },
        .mode = mode,
        .use = .linear,
    } } });
    const returns = try b.declare(&.{number}, number, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    const clause = try b.declare(&.{ unit, token }, number, &.{deliberate}, &.{});
    const handler = try b.handler(.{ .mode = mode, .input = number, .answer = number, .effects = &.{
        deliberate,
    }, .return_function = returns, .clauses = &.{.{
        .effect = local,
        .function = clause,
        .resumption = token,
    }} });
    try b.define(clause, if (shallow)
        try b.term(.{ .resume_with = .{
            .resumption = try b.reference(b.parameter(clause, 1)),
            .argument = try b.constant(void, {}),
            .handler = handler,
        } })
    else
        try b.term(.{ .resume_value = .{
            .resumption = try b.reference(b.parameter(clause, 1)),
            .argument = try b.constant(void, {}),
        } }));
    return controllerHandledBody(b, original, input, number, capability, deliberate, handler);
}

pub fn controllerWithUnusedImport(b: *source.Builder) !source.Module {
    const original = try controller(b, false);
    _ = try b.effect(.{
        .identity = "controller/1/snapshot",
        .payload = try b.scalar(u64),
        .result = try b.scalar(void),
        .external = false,
    });
    return b.module(original.entry, original.failure);
}

pub fn retainedHandlers(b: *source.Builder, shallow: bool) !source.Module {
    const original = if (shallow) try source.examples.shallowResumptions(
        b,
    ) else try source.examples.successorState(b);
    // These fixtures supply every capability explicitly. Making their effects
    // internal permits source ingestion without changing attachment identity.
    for (b.effects.items) |*effect| effect.external = false;
    const function = b.functions.items[@intCast(original.entry)];
    const root = try b.declare(
        &.{try b.scalar(void)},
        function.result,
        function.effects,
        function.regions,
    );
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
    const info = try @import("horos").source.library.cleanup.exitInfo(b, unit);
    const observed = try b.effect(.{
        .identity = "example/disposal",
        .payload = info,
        .result = unit,
        .external = false,
    });
    const body = try b.declare(&.{}, u, &.{}, &.{});
    try b.define(body, try b.term(.{ .yield_then = try b.pure(try b.constant(u64, 42)) }));
    const cleanup = try b.declare(&.{info}, unit, &.{observed}, &.{});
    const requested = try b.term(.{ .perform = .{
        .effect = observed,
        .payload = try b.reference(b.parameter(cleanup, 0)),
    } });
    const finished = try b.term(.{ .yield_then = try b.pure(try b.constant(void, {})) });
    try b.define(
        cleanup,
        try b.term(.{
            .yield_then = if (request) try b.bind(
                try b.variable(unit),
                requested,
                finished,
            ) else try b.pure(try b.constant(void, {})),
        }),
    );
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = u,
    } } });
    const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{
        info,
    }, .result = unit, .effects = &.{observed} } } });
    const entry = try b.declare(&.{unit}, u, &.{observed}, &.{});
    try b.define(
        entry,
        try b.term(.{ .protect = .{
            .body = try b.lambda(body, body_type),
            .cleanup = try b.lambda(cleanup, cleanup_type),
        } }),
    );
    return b.module(entry, unit);
}

pub fn distinctAttachments(b: *source.Builder) !source.Module {
    const unit = try b.scalar(void);
    const u = try b.scalar(u64);
    const effect = try b.effect(.{
        .identity = "example/attachments",
        .payload = unit,
        .result = u,
        .external = false,
    });
    const cap = try b.schema(.{ .internal = .{ .capability = effect } });
    const returns = try b.declare(&.{u}, u, &.{}, &.{});
    try b.define(returns, try b.pure(try b.reference(b.parameter(returns, 0))));
    const handlers = try attachmentHandlers(b, unit, u, effect, cap, returns);
    const body = try b.declare(&.{ cap, cap }, u, &.{effect}, &.{});
    try b.define(
        body,
        try b.term(.{ .perform = .{
            .effect = effect,
            .capability = try b.reference(b.parameter(body, 1)),
            .payload = try b.constant(void, {}),
        } }),
    );
    const body_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{
        cap,
        cap,
    }, .result = u, .effects = &.{effect} } } });
    const outer = try b.declare(&.{cap}, u, &.{effect}, &.{});
    try b.define(
        outer,
        try b.term(.{ .handle = .{ .handler = handlers[1], .body = try b.lambda(
            body,
            body_type,
        ), .arguments = &.{try b.reference(b.parameter(outer, 0))} } }),
    );
    const outer_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{
        cap,
    }, .result = u, .effects = &.{effect} } } });
    const main = try b.declare(&.{unit}, u, &.{effect}, &.{});
    try b.define(
        main,
        try b.term(.{ .handle = .{
            .handler = handlers[0],
            .body = try b.lambda(outer, outer_type),
        } }),
    );
    return b.module(main, unit);
}

pub fn binaryQuestion(b: *source.Builder) !source.Module {
    const unit = try b.scalar(void);
    const boolean = try b.scalar(bool);
    const ask = try b.effect(.{
        .identity = "example/binary-question",
        .payload = unit,
        .result = boolean,
        .external = false,
    });
    const entry = try b.declare(&.{unit}, boolean, &.{ask}, &.{});
    try b.define(
        entry,
        try b.term(.{ .perform = .{ .effect = ask, .payload = try b.constant(void, {}) } }),
    );
    return b.module(entry, unit);
}

pub fn reusableQuestion(b: *source.Builder, increment: u64) !source.Module {
    const unit = try b.scalar(void);
    const number = try b.scalar(u64);
    const helper = try b.declare(&.{number}, number, &.{}, &.{});
    try b.define(helper, try b.pure(try reusableAdd(
        b,
        number,
        try b.reference(b.parameter(helper, 0)),
        try b.constant(u64, increment),
    )));
    const ask = try b.effect(.{
        .identity = "example/current-adjustment",
        .payload = number,
        .result = number,
        .external = false,
    });
    const entry = try b.declare(&.{number}, number, &.{ask}, &.{});
    const adjusted = try b.variable(number);
    const answer = try b.variable(number);
    const initial = try b.reference(b.parameter(entry, 0));
    try b.define(entry, try b.bind(adjusted, try b.term(.{ .call = .{
        .function = helper,
        .arguments = &.{initial},
    } }), try b.bind(answer, try b.term(.{ .perform = .{
        .effect = ask,
        .payload = initial,
    } }), try b.pure(try reusableAdd(
        b,
        number,
        try b.reference(adjusted),
        try b.reference(answer),
    )))));
    return b.module(entry, unit);
}

fn reusableAdd(
    b: *source.Builder,
    schema: source.Id,
    left: source.Id,
    right: source.Id,
) !source.Id {
    const fault = try b.failureLiteral(try b.constant(void, {}));
    return b.value(.{ .schema = schema, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ left, right },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }},
    } } });
}

pub const SemanticGuestInput = struct { yields: u64, seed: u64 };

pub fn semanticGuest(b: *source.Builder) !source.Module {
    const question = try binaryQuestion(b);
    const branches = try mutableAlternatives(b);
    const unit = question.failure;
    const number = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const input = try @import("protean_contracts").schema(SemanticGuestInput, b);
    const question_effect = b.functions.items[@intCast(question.entry)].effects[0];
    const alternative_effects = b.functions.items[@intCast(branches.entry)].effects;
    const effects = [_]source.Id{ question_effect, alternative_effects[0], alternative_effects[1] };
    const info = try @import("horos").source.library.cleanup.exitInfo(b, unit);
    const body = try b.declare(&.{}, boolean, &.{question_effect}, &.{});
    const answer = try b.variable(boolean);
    try b.define(body, try b.bind(answer, try b.term(.{ .call = .{
        .function = question.entry,
        .arguments = &.{try b.constant(void, {})},
    } }), try b.term(.{ .yield_then = try b.pure(try b.reference(answer)) })));
    const cleanup = try b.declare(&.{info}, unit, &.{}, &.{});
    try b.define(cleanup, try b.term(.{ .yield_then = try b.pure(try b.constant(void, {})) }));
    const body_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{},
        .result = boolean,
        .effects = &.{question_effect},
    } } });
    const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{
        .parameters = &.{info},
        .result = unit,
    } } });
    const run = try b.declare(&.{number}, number, &effects, &.{});
    const protected_answer = try b.variable(boolean);
    const true_branch = try b.term(.{ .call = .{
        .function = branches.entry,
        .arguments = &.{try b.reference(b.parameter(run, 0))},
    } });
    const false_branch = try b.pure(try b.constant(u64, 0));
    const selected = try b.term(.{ .conditional = .{
        .condition = try b.reference(protected_answer),
        .when_true = true_branch,
        .when_false = false_branch,
    } });
    try b.define(run, try b.bind(protected_answer, try b.term(.{ .protect = .{
        .body = try b.lambda(body, body_type),
        .cleanup = try b.lambda(cleanup, cleanup_type),
    } }), selected));
    return semanticPrefix(b, number, boolean, input, &effects, run, unit);
}

pub fn mutableAlternatives(b: *source.Builder) !source.Module {
    const u = try b.scalar(u64);
    const unit = try b.scalar(void);
    const prefix = try b.effect(.{
        .identity = "example/prefix",
        .payload = u,
        .result = unit,
        .external = false,
    });
    const ask = try b.effect(.{
        .identity = "example/alternative",
        .payload = unit,
        .result = u,
        .external = false,
        .control_use = .multi,
    });
    const r = b.region();
    const region = try b.schema(.{ .internal = .{ .region = r } });
    const cell = try b.schema(.{ .internal = .{ .cell = .{ .element = u, .region = r } } });
    const main = try b.declare(&.{u}, u, &.{ prefix, ask }, &.{});
    const inside = try b.declare(&.{ region, u }, u, &.{ prefix, ask }, &.{r});
    try defineMutableBody(b, u, unit, prefix, ask, cell, inside);
    const body = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{
        region,
        u,
    }, .result = u, .effects = &.{ prefix, ask }, .regions = &.{r} } } });
    try b.define(
        main,
        try b.term(.{ .with_region = .{ .region = r, .body = try b.lambda(
            inside,
            body,
        ), .arguments = &.{try b.reference(b.parameter(main, 0))} } }),
    );
    return b.module(main, unit);
}

pub fn exclusiveAlternative(b: *source.Builder) !source.Module {
    const u = try b.scalar(u64);
    const unit = try b.scalar(void);
    const resource = try b.resource(u);
    const ask = try b.effect(.{
        .identity = "example/exclusive",
        .payload = unit,
        .result = unit,
        .external = false,
        .control_use = .multi,
    });
    const factory = try b.declare(&.{}, resource, &.{}, &.{});
    const consume = try b.declare(&.{resource}, u, &.{}, &.{});
    try b.resourceAuthority(resource, &.{factory}, &.{consume});
    try b.define(
        factory,
        try b.pure(try b.primitive(resource, .resource_pack, &.{try b.constant(u64, 42)}, 0)),
    );
    try b.define(
        consume,
        try b.pure(
            try b.primitive(u, .resource_unpack, &.{try b.reference(b.parameter(consume, 0))}, 0),
        ),
    );
    const main = try b.declare(&.{unit}, u, &.{ask}, &.{});
    const owned = try b.variable(resource);
    const result = try b.term(.{ .call = .{ .function = consume, .arguments = &.{
        try b.reference(owned),
    } } });
    const pause = try b.bind(
        try b.variable(unit),
        try b.term(.{ .perform = .{ .effect = ask, .payload = try b.constant(void, {}) } }),
        result,
    );
    try b.define(
        main,
        try b.bind(
            owned,
            try b.term(.{ .call = .{ .function = factory, .arguments = &.{} } }),
            pause,
        ),
    );
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
    const rem = try b.value(
        .{ .schema = u, .expression = .{ .primitive = .{ .opcode = .integer_rem, .operands = &.{
            x,
            y,
        }, .failures = &.{
            .{ .kind = .arithmetic_overflow, .value = fault },
            .{ .kind = .division_by_zero, .value = fault },
        } } } },
    );
    const done = try b.pure(x);
    const again = try b.term(.{ .call = .{ .function = recur, .arguments = &.{ y, rem } } });
    try b.define(
        recur,
        try b.term(.{ .conditional = .{
            .condition = condition,
            .when_true = done,
            .when_false = again,
        } }),
    );
    const left = try b.variable(u);
    const right = try b.variable(u);
    const run = try b.term(.{ .call = .{ .function = recur, .arguments = &.{
        try b.reference(left),
        try b.reference(right),
    } } });
    try b.define(
        entry,
        try b.term(.{ .unpack_product = .{
            .value = try b.reference(b.parameter(entry, 0)),
            .variables = &.{ left, right },
            .body = run,
        } }),
    );
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
    const call = try b.term(.{ .call = .{ .function = recurse, .arguments = &.{
        try b.reference(tail),
    } } });
    const joined = try b.bind(length, call, try b.pure(incremented));
    const yielded = if (yields) try b.term(.{ .yield_then = joined }) else joined;
    const unpack = try b.term(.{ .unpack_product = .{
        .value = try b.reference(nonempty),
        .variables = &.{ head, tail },
        .body = yielded,
    } });
    const done = try b.pure(try b.constant(u64, 0));
    try b.define(recurse, try b.term(.{ .match_sum = .{ .value = try b.reference(
        b.parameter(recurse, 0),
    ), .cases = &.{
        .{ .variable = empty, .body = done }, .{ .variable = nonempty, .body = unpack },
    } } }));
    return b.module(recurse, unit);
}

pub fn alternatives(b: *source.Builder, multi: bool) !source.Module {
    const u = try b.scalar(u64);
    const unit = try b.scalar(void);
    const emitted = try b.effect(.{
        .identity = "example/prefix",
        .payload = u,
        .result = unit,
        .external = false,
    });
    const ask = try b.effect(.{
        .identity = "example/alternative",
        .payload = unit,
        .result = u,
        .external = false,
        .control_use = if (multi) .multi else .linear,
    });
    const entry = try b.declare(&.{u}, u, &.{ emitted, ask }, &.{});
    const prefix_value = try b.variable(u);
    const ignored = try b.variable(unit);
    const answer = try b.variable(u);
    const fault = try b.failureLiteral(try b.constant(void, {}));
    const prefix = try b.value(
        .{ .schema = u, .expression = .{ .primitive = .{ .opcode = .integer_add, .operands = &.{
            try b.reference(b.parameter(entry, 0)),
            try b.constant(u64, 1),
        }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }} } } },
    );
    const result = try b.value(
        .{ .schema = u, .expression = .{ .primitive = .{ .opcode = .integer_add, .operands = &.{
            try b.reference(prefix_value),
            try b.reference(answer),
        }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }} } } },
    );
    const branch = try b.bind(
        answer,
        try b.term(.{ .perform = .{ .effect = ask, .payload = try b.constant(void, {}) } }),
        try b.pure(result),
    );
    const emit = try b.bind(
        ignored,
        try b.term(.{ .perform = .{
            .effect = emitted,
            .payload = try b.reference(prefix_value),
        } }),
        branch,
    );
    try b.define(entry, try b.bind(prefix_value, try b.pure(prefix), emit));
    return b.module(entry, unit);
}

pub const Reconstruction = struct {
    const c = @import("protean_contracts");
    const data = @import("horos_data");
    const Id = source.Id;
    pub const Input = c.Vector(u64, null);
    pub const Output = struct { total: u64, covered: u64, instruction_cut: u64 };
    pub const Direct = struct {
        records: Input,
        position: u64,
        total: u64,
        covered: u64,
        instruction_cut: u64,
        revisit: bool,
    };
    pub const Indexed = struct {
        records: Input,
        index: Input,
        cursor: u64,
        total: u64,
        covered: u64,
        instruction_cut: u64,
        exceptional: u64,
    };
    pub const Private = union(enum) { initial: Input, @"resume": Direct };
    pub const Proposal = struct {
        position: u64,
        value: u64,
        total: u64,
        covered: u64,
        indexed: bool,
        instruction_cut: u64,
    };
    pub const Response = union(enum) {
        next: void,
        adopt: c.workspace.Adoption,
        inspect: c.workspace.Ref,
        realize: @FieldType(c.workspace.Work, "realize_controller"),
    };
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
            return e.b.value(.{ .schema = try e.schema(
                u64,
            ), .expression = .{ .primitive = .{ .opcode = opcode, .operands = &.{
                left,
                right,
            }, .failures = &.{.{
                .kind = .arithmetic_overflow,
                .value = try e.b.failureLiteral(try e.b.constant(void, {})),
            }} } } });
        }
        fn get(e: E, list: Id, index: Id) !Id {
            const optional = try e.b.schema(.{ .sum = &.{
                try e.schema(void),
                try e.schema(u64),
            } });
            const found = try e.b.primitive(optional, .sequence_get, &.{ list, index }, 0);
            return e.b.value(.{ .schema = try e.schema(
                u64,
            ), .expression = .{ .primitive = .{ .opcode = .variant_payload, .operands = &.{
                found,
            }, .immediate = 1, .failures = &.{.{
                .kind = .invalid_variant,
                .value = try e.b.failureLiteral(try e.b.constant(void, {})),
            }} } } });
        }
        fn length(e: E, list: Id) !Id {
            return e.b.primitive(try e.schema(u64), .sequence_length, &.{list}, 0);
        }
        fn choose(e: E, condition: Id, yes: Id, no: Id) !Id {
            return e.b.term(.{ .conditional = .{
                .condition = condition,
                .when_true = yes,
                .when_false = no,
            } });
        }
        fn call(e: E, function: Id, arguments: []const Id) !Id {
            return e.b.term(.{ .call = .{ .function = function, .arguments = arguments } });
        }
        fn result(e: E, state: Id, indexed: bool) !Id {
            return e.b.pure(
                try e.product(Output, &.{
                    try e.field(u64, state, if (indexed) 3 else 2),
                    try e.field(u64, state, if (indexed) 4 else 3),
                    try e.field(u64, state, if (indexed) 5 else 4),
                }),
            );
        }
    };
    pub fn controller(b: *source.Builder, indexed: bool, cleanup: bool) !source.Module {
        return controllerWithCleanup(b, indexed, cleanup, null, 0);
    }
    pub fn controllerWithCleanup(
        b: *source.Builder,
        indexed: bool,
        cleanup: bool,
        workspace_command: ?c.workspace.Command,
        cleanup_steps: usize,
    ) !source.Module {
        return controllerWithReplay(b, indexed, cleanup, workspace_command, cleanup_steps, false);
    }
    pub fn controllerWithReplay(
        b: *source.Builder,
        indexed: bool,
        cleanup: bool,
        workspace_command: ?c.workspace.Command,
        cleanup_steps: usize,
        replay_adoption: bool,
    ) !source.Module {
        return controllerWithActions(
            b,
            indexed,
            cleanup,
            workspace_command,
            cleanup_steps,
            replay_adoption,
            false,
        );
    }
    pub fn controllerWithActions(
        b: *source.Builder,
        indexed: bool,
        cleanup: bool,
        workspace_command: ?c.workspace.Command,
        cleanup_steps: usize,
        replay_adoption: bool,
        realize_runtime: bool,
    ) !source.Module {
        const e: E = .{ .b = b };
        const unit = try e.schema(void);
        const state_schema = if (indexed) try e.schema(Indexed) else try e.schema(Direct);
        const private = if (indexed) state_schema else try e.schema(Private);
        const input = try b.schema(.{ .product = &.{
            try e.schema(c.controller.TaskAnchor),
            private,
        } });
        const payload = try b.schema(.{ .product = &.{ try e.schema(Proposal), state_schema } });
        const reply = try e.schema(c.controller.Reply(Response));
        const deliberate = try b.effect(.{
            .identity = "controller/1/deliberate",
            .payload = payload,
            .result = reply,
            .external = false,
        });
        const has_workspace = workspace_command != null or replay_adoption or realize_runtime;
        const workspace_effect = if (has_workspace) try b.effect(.{
            .identity = "controller/1/workspace",
            .payload = try e.schema(c.workspace.Command),
            .result = try e.schema(c.workspace.Reply),
            .external = false,
        }) else null;
        const main_effects: []const Id = if (replay_adoption or realize_runtime)
            try b.allocator().dupe(Id, &.{ deliberate, workspace_effect.? })
        else
            &.{deliberate};
        const signature: ControllerSignature = .{
            .unit = unit,
            .state_schema = state_schema,
            .input = input,
            .payload = payload,
            .reply = reply,
            .deliberate = deliberate,
            .workspace_effect = workspace_effect,
            .main_effects = main_effects,
        };
        const iteration = try controllerIteration(e, signature, indexed);
        if (indexed) try indexedController(
            e,
            signature,
            iteration,
        ) else try directController(
            e,
            signature,
            iteration,
            replay_adoption,
            realize_runtime,
        );
        const body = try controllerBody(e, signature, iteration.loop, indexed);
        if (!cleanup) return b.module(body, unit);
        return controllerCleanup(e, signature, body, workspace_command, cleanup_steps);
    }
    const ControllerSignature = struct {
        unit: Id,
        state_schema: Id,
        input: Id,
        payload: Id,
        reply: Id,
        deliberate: Id,
        workspace_effect: ?Id,
        main_effects: []const Id,
    };
    const ControllerIteration = struct {
        loop: Id,
        state: Id,
        records: Id,
        position: Id,
        selected: Id,
        item: Id,
        total: Id,
        covered: Id,
        cut: Id,
        next_position: Id,
        next_total: Id,
        next_covered: Id,
        response: Id,
        next_state: Id,
        next: Id,
    };
    fn controllerIteration(
        e: E,
        signature: ControllerSignature,
        indexed: bool,
    ) !ControllerIteration {
        const b = e.b;
        const loop = try b.declare(
            &.{signature.state_schema},
            try e.schema(Output),
            signature.main_effects,
            &.{},
        );
        const state = try b.reference(b.parameter(loop, 0));
        const records = try e.field(Input, state, 0);
        const position = try e.field(u64, state, if (indexed) 2 else 1);
        const selected = if (indexed) try e.get(
            try e.field(Input, state, 1),
            position,
        ) else position;
        const item = try e.get(records, selected);
        const total = try e.field(u64, state, if (indexed) 3 else 2);
        const covered = try e.field(u64, state, if (indexed) 4 else 3);
        const cut = try e.field(u64, state, if (indexed) 5 else 4);
        const next_position = try e.arithmetic(.integer_add, position, try e.number(1));
        const next_total = try e.arithmetic(.integer_add, total, item);
        const next_covered = try e.arithmetic(.integer_add, covered, try e.number(1));
        const response = try b.variable(signature.reply);
        const next_state = try b.variable(signature.state_schema);
        const next = try b.reference(next_state);
        return .{
            .loop = loop,
            .state = state,
            .records = records,
            .position = position,
            .selected = selected,
            .item = item,
            .total = total,
            .covered = covered,
            .cut = cut,
            .next_position = next_position,
            .next_total = next_total,
            .next_covered = next_covered,
            .response = response,
            .next_state = next_state,
            .next = next,
        };
    }
    fn indexedController(
        e: E,
        signature: ControllerSignature,
        iteration: ControllerIteration,
    ) !void {
        const b = e.b;
        const exceptional = try b.variable(try e.schema(u64));
        const is_exceptional = try b.primitive(
            try e.schema(bool),
            .less,
            &.{ try e.number(100), iteration.item },
            0,
        );
        const updated = try e.product(Indexed, &.{
            iteration.records,
            try e.field(Input, iteration.state, 1),
            iteration.next_position,
            iteration.next_total,
            iteration.next_covered,
            iteration.cut,
            try b.reference(exceptional),
        });
        const step = try b.bind(
            exceptional,
            try e.choose(
                is_exceptional,
                try b.pure(iteration.selected),
                try b.pure(try e.field(u64, iteration.state, 6)),
            ),
            try e.call(iteration.loop, &.{updated}),
        );
        const proposal = try e.product(Proposal, &.{
            try e.field(u64, iteration.state, 6),
            try e.get(iteration.records, try e.field(u64, iteration.state, 6)),
            iteration.total,
            iteration.covered,
            try b.constant(bool, true),
            iteration.cut,
        });
        const done = try b.bind(
            iteration.response,
            try b.term(.{ .perform = .{
                .effect = signature.deliberate,
                .payload = try b.primitive(
                    signature.payload,
                    .product,
                    &.{ proposal, iteration.state },
                    0,
                ),
            } }),
            try e.result(iteration.state, true),
        );
        try b.define(
            iteration.loop,
            try e.choose(
                try b.primitive(
                    try e.schema(bool),
                    .less,
                    &.{ iteration.position, try e.length(try e.field(Input, iteration.state, 1)) },
                    0,
                ),
                step,
                done,
            ),
        );
    }
    fn directController(
        e: E,
        signature: ControllerSignature,
        iteration: ControllerIteration,
        replay_adoption: bool,
        realize_runtime: bool,
    ) !void {
        const b = e.b;
        const ordinary = try e.product(Direct, &.{
            iteration.records,
            iteration.next_position,
            iteration.next_total,
            iteration.next_covered,
            iteration.cut,
            try b.constant(bool, false),
        });
        const revisited = try e.product(Direct, &.{
            iteration.records,
            try e.length(iteration.records),
            iteration.total,
            iteration.covered,
            iteration.cut,
            try b.constant(bool, false),
        });
        const proposal = try e.product(Proposal, &.{
            iteration.selected,
            iteration.item,
            try e.field(u64, iteration.next, 2),
            try e.field(u64, iteration.next, 3),
            try b.constant(bool, false),
            iteration.cut,
        });
        const continued = try e.call(iteration.loop, &.{iteration.next});
        const settled = if (replay_adoption or realize_runtime)
            try controllerResponse(
                e,
                signature,
                iteration,
                continued,
                replay_adoption,
                realize_runtime,
            )
        else
            continued;
        try defineDirectIteration(e, signature, iteration, ordinary, revisited, proposal, settled);
    }
    fn defineDirectIteration(
        e: E,
        signature: ControllerSignature,
        iteration: ControllerIteration,
        ordinary: Id,
        revisited: Id,
        proposal: Id,
        settled: Id,
    ) !void {
        const b = e.b;
        const interact = try b.bind(
            iteration.response,
            try b.term(.{ .perform = .{
                .effect = signature.deliberate,
                .payload = try b.primitive(
                    signature.payload,
                    .product,
                    &.{ proposal, iteration.next },
                    0,
                ),
            } }),
            settled,
        );
        const step = try b.bind(
            iteration.next_state,
            try e.choose(
                try e.field(bool, iteration.state, 5),
                try b.pure(revisited),
                try b.pure(ordinary),
            ),
            interact,
        );
        try b.define(
            iteration.loop,
            try e.choose(
                try b.primitive(
                    try e.schema(bool),
                    .less,
                    &.{ iteration.position, try e.length(iteration.records) },
                    0,
                ),
                step,
                try e.result(iteration.state, false),
            ),
        );
    }
    const ResponseCommands = struct {
        ordinary_response: Id,
        adoption: Id,
        performed: Id,
        inspected: Id,
        inspect_command: Id,
        realization: Id,
        realize_command: Id,
    };
    fn responseCommands(e: E, signature: ControllerSignature) !ResponseCommands {
        const b = e.b;
        const ordinary_response = try b.variable(signature.unit);
        const adoption = try b.variable(try e.schema(c.workspace.Adoption));
        const program = try b.primitive(
            try e.schema(c.workspace.Program),
            .variant,
            &.{try b.reference(adoption)},
            @backingInt(@as(@import("std").meta.Tag(c.workspace.Program), .adopt)),
        );
        const command = try b.primitive(
            try e.schema(c.workspace.Command),
            .variant,
            &.{program},
            @backingInt(@as(@import("std").meta.Tag(c.workspace.Command), .program)),
        );
        const performed = try b.term(.{ .perform = .{
            .effect = signature.workspace_effect.?,
            .payload = command,
        } });
        const inspected = try b.variable(try e.schema(c.workspace.Ref));
        const inspection = try e.product(@FieldType(
            c.workspace.Work,
            "inspect",
        ), &.{try b.reference(inspected)});
        const work = try b.primitive(
            try e.schema(c.workspace.Work),
            .variant,
            &.{inspection},
            @backingInt(@as(@import("std").meta.Tag(c.workspace.Work), .inspect)),
        );
        const inspect_command = try b.primitive(
            try e.schema(c.workspace.Command),
            .variant,
            &.{work},
            @backingInt(@as(@import("std").meta.Tag(c.workspace.Command), .work)),
        );
        const realization = try b.variable(
            try e.schema(@FieldType(c.workspace.Work, "realize_controller")),
        );
        const realize_work = try b.primitive(
            try e.schema(c.workspace.Work),
            .variant,
            &.{try b.reference(realization)},
            @backingInt(
                @as(@import("std").meta.Tag(c.workspace.Work), .realize_controller),
            ),
        );
        const realize_command = try b.primitive(
            try e.schema(c.workspace.Command),
            .variant,
            &.{realize_work},
            @backingInt(@as(@import("std").meta.Tag(c.workspace.Command), .work)),
        );
        return .{
            .ordinary_response = ordinary_response,
            .adoption = adoption,
            .performed = performed,
            .inspected = inspected,
            .inspect_command = inspect_command,
            .realization = realization,
            .realize_command = realize_command,
        };
    }
    fn controllerResponse(
        e: E,
        signature: ControllerSignature,
        iteration: ControllerIteration,
        continued: Id,
        replay_adoption: bool,
        realize_runtime: bool,
    ) !Id {
        const b = e.b;
        const commands = try responseCommands(e, signature);
        return b.term(.{ .match_sum = .{ .value = try e.field(
            Response,
            try b.reference(iteration.response),
            0,
        ), .cases = &.{
            .{ .variable = commands.ordinary_response, .body = continued },
            .{
                .variable = commands.adoption,
                .body = if (replay_adoption) try b.bind(
                    try b.variable(try e.schema(c.workspace.Reply)),
                    commands.performed,
                    continued,
                ) else continued,
            },
            .{
                .variable = commands.inspected,
                .body = if (replay_adoption) try b.bind(
                    try b.variable(try e.schema(c.workspace.Reply)),
                    try b.term(.{ .perform = .{
                        .effect = signature.workspace_effect.?,
                        .payload = commands.inspect_command,
                    } }),
                    continued,
                ) else continued,
            },
            .{
                .variable = commands.realization,
                .body = if (realize_runtime) try b.bind(
                    try b.variable(try e.schema(c.workspace.Reply)),
                    try b.term(.{ .perform = .{
                        .effect = signature.workspace_effect.?,
                        .payload = commands.realize_command,
                    } }),
                    continued,
                ) else continued,
            },
        } } });
    }
    fn controllerBody(e: E, signature: ControllerSignature, loop: Id, indexed: bool) !Id {
        const b = e.b;
        const body = try b.declare(
            &.{signature.input},
            try e.schema(Output),
            signature.main_effects,
            &.{},
        );
        const value = if (indexed) try e.field(
            Indexed,
            try b.reference(b.parameter(body, 0)),
            1,
        ) else try e.field(Private, try b.reference(b.parameter(body, 0)), 1);
        if (indexed) {
            try b.define(body, try e.call(loop, &.{value}));
        } else {
            const original = try b.variable(try e.schema(Input));
            const resumed = try b.variable(signature.state_schema);
            const initial = try e.product(Direct, &.{
                try b.reference(original),
                try e.number(0),
                try e.number(0),
                try e.number(0),
                try e.number(1),
                try b.constant(bool, false),
            });
            try b.define(
                body,
                try b.term(.{ .match_sum = .{ .value = value, .cases = &.{ .{
                    .variable = original,
                    .body = try e.call(loop, &.{initial}),
                }, .{
                    .variable = resumed,
                    .body = try e.call(loop, &.{try b.reference(resumed)}),
                } } } }),
            );
        }
        return body;
    }
    fn controllerCleanup(
        e: E,
        signature: ControllerSignature,
        body: Id,
        workspace_command: ?c.workspace.Command,
        cleanup_steps: usize,
    ) !source.Module {
        const b = e.b;
        const info = try @import("horos").source.library.cleanup.exitInfo(b, signature.unit);
        const dispose = try b.effect(.{
            .identity = "controller/1/snapshot",
            .payload = try e.schema(u64),
            .result = signature.unit,
            .external = false,
        });
        const cleanup_effects = if (workspace_command != null) try b.allocator().dupe(@TypeOf(
            dispose,
        ), &.{ signature.workspace_effect.?, dispose }) else &.{dispose};
        const unwind = try b.declare(&.{info}, signature.unit, cleanup_effects, &.{});
        var cleanup_payload = try e.number(7);
        for (0..cleanup_steps) |_| cleanup_payload = try b.primitive(
            try e.schema(u64),
            .integer_bit_xor,
            &.{ cleanup_payload, try e.number(1) },
            0,
        );
        const cleanup_call = try b.term(.{ .perform = .{
            .effect = dispose,
            .payload = cleanup_payload,
        } });
        const disposed = if (cleanup_steps == 0) cleanup_call else try b.bind(
            try b.variable(signature.unit),
            cleanup_call,
            try b.bind(
                try b.variable(try e.schema(u64)),
                try b.pure(cleanup_payload),
                try b.pure(try b.literal(.{ .schema = signature.unit, .bytes = &.{} })),
            ),
        );
        try b.define(
            unwind,
            if (workspace_command) |command| try b.bind(
                try b.variable(try e.schema(c.workspace.Reply)),
                try b.term(.{ .perform = .{
                    .effect = signature.workspace_effect.?,
                    .payload = try b.literal(.{
                        .schema = try e.schema(c.workspace.Command),
                        .bytes = try c.encodeOwned(c.workspace.Command, b.allocator(), command),
                    }),
                } }),
                disposed,
            ) else disposed,
        );
        return protectController(e, signature, body, info, dispose, cleanup_effects, unwind);
    }
    fn protectController(
        e: E,
        signature: ControllerSignature,
        body: Id,
        info: Id,
        dispose: Id,
        cleanup_effects: []const Id,
        unwind: Id,
    ) !source.Module {
        const b = e.b;
        const body_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{signature.input},
            .result = try e.schema(Output),
            .effects = signature.main_effects,
        } } });
        const cleanup_type = try b.schema(.{ .internal = .{ .computation = .{
            .parameters = &.{info},
            .result = signature.unit,
            .effects = cleanup_effects,
        } } });
        const effects = if (signature.workspace_effect) |effect| try b.allocator().dupe(@TypeOf(
            dispose,
        ), &.{ signature.deliberate, effect, dispose }) else &.{ signature.deliberate, dispose };
        const entry = try b.declare(&.{signature.input}, try e.schema(Output), effects, &.{});
        try b.define(
            entry,
            try b.term(.{ .protect = .{ .body = try b.lambda(
                body,
                body_type,
            ), .cleanup = try b.lambda(unwind, cleanup_type), .arguments = &.{
                try b.reference(b.parameter(entry, 0)),
            } } }),
        );
        return b.module(entry, signature.unit);
    }
    pub fn converter(b: *source.Builder, to_indexed: bool, variant: enum {
        valid,
        fail,
        diverge,
    }) !source.Module {
        const e: E = .{ .b = b };
        const carry = if (to_indexed) try e.schema(Direct) else try e.schema(Indexed);
        const result = if (to_indexed) try e.schema(Indexed) else try e.schema(Private);
        const input = try b.schema(.{ .product = &.{
            carry,
            try e.schema(c.controller.OwnerView),
        } });
        const entry = try b.declare(&.{input}, result, &.{}, &.{});
        if (variant == .fail) {
            try b.define(entry, try b.term(.{ .fail = try b.constant(void, {}) }));
        } else if (variant == .diverge) {
            try b.define(entry, try e.call(entry, &.{try b.reference(b.parameter(entry, 0))}));
        } else {
            const argument = try b.reference(b.parameter(entry, 0));
            const state = if (to_indexed) try e.field(
                Direct,
                argument,
                0,
            ) else try e.field(
                Indexed,
                argument,
                0,
            );
            const view = try e.field(c.controller.OwnerView, argument, 1);
            const cut = try e.field(u64, view, 2);
            const records = try e.field(Input, state, 0);
            if (to_indexed) {
                try defineIndexedConverter(e, entry, state, cut, records);
            } else {
                const direct = try e.product(Direct, &.{
                    records,
                    try e.field(u64, state, 6),
                    try e.field(u64, state, 3),
                    try e.field(u64, state, 4),
                    cut,
                    try b.constant(bool, true),
                });
                try b.define(entry, try b.pure(try b.primitive(result, .variant, &.{direct}, 1)));
            }
        }
        return b.module(entry, try e.schema(void));
    }
    fn defineIndexedConverter(e: E, entry: Id, state: Id, cut: Id, records: Id) !void {
        const b = e.b;
        const index = try b.declare(&.{
            try e.schema(u64),
            try e.schema(u64),
            try e.schema(Input),
        }, try e.schema(Input), &.{}, &.{});
        const cursor = try b.reference(b.parameter(index, 0));
        const end = try b.reference(b.parameter(index, 1));
        const prior = try b.reference(b.parameter(index, 2));
        const previous = try e.arithmetic(.integer_sub, cursor, try e.number(1));
        const appended = try b.primitive(
            try e.schema(Input),
            .sequence_append,
            &.{ prior, previous },
            0,
        );
        try b.define(
            index,
            try e.choose(
                try b.primitive(try e.schema(bool), .less, &.{ end, cursor }, 0),
                try e.call(index, &.{ previous, end, appended }),
                try b.pure(prior),
            ),
        );
        const indexes = try b.variable(try e.schema(Input));
        const built = try e.product(Indexed, &.{
            records,
            try b.reference(indexes),
            try e.number(0),
            try e.field(u64, state, 2),
            try e.field(u64, state, 3),
            cut,
            try e.number(0),
        });
        try b.define(
            entry,
            try b.bind(
                indexes,
                try e.call(index, &.{
                    try e.length(records),
                    try e.field(u64, state, 1),
                    try b.primitive(try e.schema(Input), .sequence, &.{}, 0),
                }),
                try b.pure(built),
            ),
        );
    }
};

pub fn cutObserver(b: *source.Builder, fails: bool) !source.Module {
    const data = @import("horos_data");
    const views = @import("kosmos").RuntimeViews;
    const view = try data.schema.native.lower(data.schema.native.info(views.GuestView), b);
    const envelope = try data.schema.native.lower(
        data.schema.native.info(@import("protean_native").workspace.ObserverEnvelope),
        b,
    );
    const disclosed = try b.schema(.{ .product = &.{ envelope, view } });
    const binding = try data.schema.native.lower(data.schema.native.info(views.Binding), b);
    const number = try b.scalar(u64);
    const unit = try b.scalar(void);
    const input = try b.schema(.{ .product = &.{ disclosed, number } });
    const output = try b.schema(.{ .product = &.{ number, number } });
    const entry = try b.declare(&.{input}, output, &.{}, &.{});
    const parameter = try b.reference(b.parameter(entry, 0));
    const selected = try b.primitive(disclosed, .field, &.{parameter}, 0);
    const cut = try b.primitive(view, .field, &.{selected}, 1);
    const before = try b.primitive(number, .field, &.{parameter}, 1);
    const provenance = try b.primitive(binding, .field, &.{cut}, 0);
    const revision = try b.primitive(number, .field, &.{provenance}, 5);
    const sum = try b.value(.{ .schema = number, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ before, revision },
        .failures = &.{.{
            .kind = .arithmetic_overflow,
            .value = try b.failureLiteral(try b.constant(void, {})),
        }},
    } } });
    const nodes = try data.schema.native.lower(data.schema.native.info([]const views.Node), b);
    const list = try b.primitive(nodes, .field, &.{cut}, 2);
    const count = try b.primitive(number, .sequence_length, &.{list}, 0);
    const result = try b.primitive(output, .product, &.{ sum, count }, 0);
    try b.define(entry, if (fails)
        try b.term(.{ .fail = try b.constant(void, {}) })
    else
        try b.pure(result));
    return b.module(entry, unit);
}

pub const RetentionObservation = struct {
    target: u64,
    emitted: struct {
        relation: @import("kosmos").RuntimeViews.queries.RetentionResult,
        request_all_nodes: bool,
    },
};

pub fn retentionObserver(b: *source.Builder) !source.Module {
    const data = @import("horos_data");
    const c = @import("protean_contracts");
    const query = try @import("kosmos").RuntimeViews.queries.retention(b);
    const query_function = b.functions.items[@intCast(query.entry)];
    const query_input = b.variables.items[@intCast(query_function.parameters[0])];
    const query_result = query_function.result;
    const view = try data.schema.native.lower(
        data.schema.native.info(@import("kosmos").RuntimeViews.GuestView),
        b,
    );
    const envelope = try c.schema(@import("protean_native").workspace.ObserverEnvelope, b);
    const disclosed = try b.schema(.{ .product = &.{ envelope, view } });
    const number = try b.scalar(u64);
    const boolean = try b.scalar(bool);
    const input = try b.schema(.{ .product = &.{ disclosed, number } });
    const output = try c.schema(RetentionObservation, b);
    const emitted = try c.schema(@FieldType(RetentionObservation, "emitted"), b);
    const Conclusion = @FieldType(
        @import("kosmos").RuntimeViews.queries.RetentionResult,
        "conclusion",
    );
    const conclusion = try c.schema(Conclusion, b);
    const ordinal = try b.scalar(u32);
    const unknown = try b.constant(u32, @backingInt(Conclusion.unknown_partial));
    const entry = try b.declare(&.{input}, output, &.{}, &.{});
    const argument = try b.reference(b.parameter(entry, 0));
    const selected = try b.primitive(disclosed, .field, &.{argument}, 0);
    const cut = try b.primitive(view, .field, &.{selected}, 1);
    const target = try b.primitive(number, .field, &.{argument}, 1);
    const result = try b.variable(query_result);
    const relation = try b.reference(result);
    const disposition = try b.primitive(conclusion, .field, &.{relation}, 1);
    const tag = try b.primitive(ordinal, .enum_tag, &.{disposition}, 0);
    const request = try b.primitive(boolean, .equal, &.{ tag, unknown }, 0);
    const observation = try b.primitive(emitted, .product, &.{ relation, request }, 0);
    try b.define(entry, try b.bind(result, try b.term(.{ .call = .{
        .function = query.entry,
        .arguments = &.{try b.primitive(query_input, .product, &.{ cut, target }, 0)},
    } }), try b.pure(try b.primitive(output, .product, &.{ target, observation }, 0))));
    return b.module(entry, query.failure);
}

pub fn outerCutObserver(b: *source.Builder) !source.Module {
    const data = @import("horos_data");
    const view = try data.schema.native.lower(
        data.schema.native.info(@import("kosmos").RuntimeCapsule.OuterView),
        b,
    );
    const envelope = try data.schema.native.lower(
        data.schema.native.info(@import("protean_native").workspace.ObserverEnvelope),
        b,
    );
    const disclosed = try b.schema(.{ .product = &.{ envelope, view } });
    const number = try b.scalar(u64);
    const unit = try b.scalar(void);
    const input = try b.schema(.{ .product = &.{ disclosed, number } });
    const output = try b.schema(.{ .product = &.{ number, number } });
    const entry = try b.declare(&.{input}, output, &.{}, &.{});
    const parameter = try b.reference(b.parameter(entry, 0));
    const selected = try b.primitive(disclosed, .field, &.{parameter}, 0);
    const event = try b.primitive(envelope, .field, &.{selected}, 0);
    const cursor = try b.primitive(number, .field, &.{event}, 2);
    const before = try b.primitive(number, .field, &.{parameter}, 1);
    const sum = try b.value(.{ .schema = number, .expression = .{ .primitive = .{
        .opcode = .integer_add,
        .operands = &.{ before, cursor },
        .failures = &.{.{
            .kind = .arithmetic_overflow,
            .value = try b.failureLiteral(try b.constant(void, {})),
        }},
    } } });
    try b.define(entry, try b.pure(try b.primitive(output, .product, &.{ sum, cursor }, 0)));
    return b.module(entry, unit);
}

fn controllerHandledBody(
    b: *source.Builder,
    original: source.Module,
    input: source.Id,
    number: source.Id,
    capability: source.Id,
    deliberate: source.Id,
    handler: source.Id,
) !source.Module {
    const body = try b.declare(&.{ capability, input }, number, &.{deliberate}, &.{});
    try b.define(
        body,
        try b.term(.{ .call = .{ .function = original.entry, .arguments = &.{
            try b.reference(b.parameter(body, 1)),
        } } }),
    );
    const body_type = try b.schema(.{ .internal = .{ .computation = .{ .parameters = &.{
        capability,
        input,
    }, .result = number, .effects = &.{deliberate} } } });
    const entry = try b.declare(&.{input}, number, &.{deliberate}, &.{});
    try b.define(
        entry,
        try b.term(.{ .handle = .{ .handler = handler, .body = try b.lambda(
            body,
            body_type,
        ), .arguments = &.{try b.reference(b.parameter(entry, 0))} } }),
    );
    return b.module(entry, original.failure);
}

fn attachmentHandlers(
    b: *source.Builder,
    unit: source.Id,
    u: source.Id,
    effect: source.Id,
    cap: source.Id,
    returns: source.Id,
) ![2]source.Id {
    var handlers: [2]source.Id = undefined;
    for (&handlers, [_]u64{ 42, 99 }) |*handler, answer| {
        const token = try b.schema(.{ .internal = .{ .resumption = .{
            .effect = effect,
            .input = u,
            .answer = u,
            .handled = &.{effect},
            .effects = &.{effect},
            .capture_bound = &.{ unit, u, cap },
            .mode = .deep,
            .use = .linear,
        } } });
        const clause = try b.declare(&.{ unit, token }, u, &.{effect}, &.{});
        try b.define(
            clause,
            try b.term(.{ .resume_value = .{
                .resumption = try b.reference(b.parameter(clause, 1)),
                .argument = try b.constant(u64, answer),
            } }),
        );
        handler.* = try b.handler(.{ .mode = .deep, .input = u, .answer = u, .effects = &.{
            effect,
        }, .return_function = returns, .clauses = &.{.{
            .effect = effect,
            .function = clause,
            .resumption = token,
        }} });
    }
    return handlers;
}

fn semanticPrefix(
    b: *source.Builder,
    number: source.Id,
    boolean: source.Id,
    input: source.Id,
    effects: []const source.Id,
    run: source.Id,
    unit: source.Id,
) !source.Module {
    const prefix = try b.declare(&.{ number, number }, number, effects, &.{});
    const remaining = try b.reference(b.parameter(prefix, 0));
    const seed = try b.reference(b.parameter(prefix, 1));
    const zero = try b.constant(u64, 0);
    const mechanical = try b.primitive(number, .integer_bit_xor, &.{ seed, zero }, 0);
    const fault = try b.failureLiteral(try b.constant(void, {}));
    const next = try b.value(.{ .schema = number, .expression = .{ .primitive = .{
        .opcode = .integer_sub,
        .operands = &.{ remaining, try b.constant(u64, 1) },
        .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }},
    } } });
    try b.define(prefix, try b.term(.{ .conditional = .{
        .condition = try b.primitive(boolean, .equal, &.{ remaining, zero }, 0),
        .when_true = try b.term(.{ .call = .{ .function = run, .arguments = &.{mechanical} } }),
        .when_false = try b.term(.{ .yield_then = try b.term(.{ .call = .{
            .function = prefix,
            .arguments = &.{ next, mechanical },
        } }) }),
    } }));
    const entry = try b.declare(&.{input}, number, effects, &.{});
    const argument = try b.reference(b.parameter(entry, 0));
    try b.define(entry, try b.term(.{ .call = .{
        .function = prefix,
        .arguments = &.{
            try b.primitive(number, .field, &.{argument}, 0),
            try b.primitive(number, .field, &.{argument}, 1),
        },
    } }));
    return b.module(entry, unit);
}

fn defineMutableBody(
    b: *source.Builder,
    u: source.Id,
    unit: source.Id,
    prefix: source.Id,
    ask: source.Id,
    cell: source.Id,
    inside: source.Id,
) !void {
    const allocated = try b.variable(cell);
    const alias = try b.variable(cell);
    const answer = try b.variable(u);
    const fault = try b.failureLiteral(try b.constant(void, {}));
    const initial = try b.value(
        .{ .schema = u, .expression = .{ .primitive = .{ .opcode = .integer_add, .operands = &.{
            try b.reference(b.parameter(inside, 1)),
            try b.constant(u64, 1),
        }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }} } } },
    );
    const before = try b.primitive(u, .cell_get, &.{try b.reference(alias)}, 0);
    const sum = try b.value(
        .{ .schema = u, .expression = .{ .primitive = .{ .opcode = .integer_add, .operands = &.{
            before,
            try b.reference(answer),
        }, .failures = &.{.{ .kind = .arithmetic_overflow, .value = fault }} } } },
    );
    const write = try b.primitive(unit, .cell_set, &.{ try b.reference(allocated), sum }, 0);
    const result = try b.pure(try b.primitive(u, .cell_get, &.{try b.reference(alias)}, 0));
    const update = try b.bind(try b.variable(unit), try b.pure(write), result);
    const choice = try b.bind(
        answer,
        try b.term(.{ .perform = .{ .effect = ask, .payload = try b.constant(void, {}) } }),
        update,
    );
    const emitted = try b.bind(
        try b.variable(unit),
        try b.term(.{ .perform = .{ .effect = prefix, .payload = initial } }),
        choice,
    );
    const aliased = try b.bind(alias, try b.pure(try b.reference(allocated)), emitted);
    try b.define(
        inside,
        try b.bind(
            allocated,
            try b.pure(
                try b.primitive(
                    cell,
                    .cell_new,
                    &.{ try b.reference(b.parameter(inside, 0)), initial },
                    0,
                ),
            ),
            aliased,
        ),
    );
}
