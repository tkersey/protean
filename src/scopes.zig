//! Lexical interpretations and explicit portable scope values. Exiting a scope
//! restores the enclosing handler; suspension retains the installed environment.
const horos = @import("horos");
const typed = horos.authoring;
const source = horos.source;
const Id = source.Id;
const sets = @import("sets.zig");
const decision = @import("decision.zig");

/// Conversation/turn/branch memory can use Horos's ordinary scoped state.
/// The caller supplies its region and chooses when/how to retain observations.
pub const state = horos.library.state;
pub const Scope = decision.Scope;
pub const Reader = struct {
    family: decision.Family,
    handler: Id,
    resumption: Id,
    environment: Id,
};

pub fn define(
    b: *source.Builder,
    identity: []const u8,
    environment: Id,
    result: Id,
    scope: Scope,
) source.Error!Reader {
    const instance = try b.specialization(Reader, "agent.scope/v1", .{
        identity, environment, result, scope,
    });
    if (instance.cached) |cached| return cached;
    const unit = try b.scalar(void);
    const family = try decision.define(b, identity, unit, environment);
    const reader = authoredReader(b, family, environment, result, scope) catch |err|
        return typed.sourceError(err);
    return instance.finish(b, reader);
}

fn authoredReader(
    b: *source.Builder,
    family: decision.Family,
    environment: Id,
    result: Id,
    scope: Scope,
) typed.Error!Reader {
    const c = try typed.Context.init(b);
    const operation = try typed.interop.operation(c, family.effect);
    const environment_schema = try typed.interop.schema(c, environment);
    const result_schema = try typed.interop.schema(c, result);
    const captures = try b.allocator().alloc(*const typed.Schema, scope.captures.len + 2);
    for (scope.captures, 0..) |id, i| captures[i] = try typed.interop.schema(c, id);
    captures[scope.captures.len] = try typed.interop.schema(c, family.capability);
    captures[scope.captures.len + 1] = environment_schema;
    const residual = try b.allocator().alloc(*const typed.Operation, scope.residual.effects.len);
    for (scope.residual.effects, residual) |id, *item| item.* = try typed.interop.operation(c, id);
    const owned = try b.allocator().alloc(*const typed.Region, scope.owned_regions.len);
    for (scope.owned_regions, owned) |id, *item| item.* = try typed.interop.region(c, id);
    const borrowed = try b.allocator().alloc(*const typed.Region, scope.borrowed_regions.len);
    for (scope.borrowed_regions, borrowed) |id, *item| item.* = try typed.interop.region(c, id);
    const handler = try c.handler(operation, result_schema, result_schema, .{
        .mode = .deep,
        .use = .linear,
        .obligations = true,
        .return_effects = &.{},
        .residual = residual,
        .captures = captures,
        .owned_regions = owned,
        .borrowed_regions = borrowed,
        .state = &.{.{ .name = "environment", .schema = environment_schema }},
    });
    const returns = try c.returnFunction(handler);
    const return_body = try c.body(returns);
    try c.define(returns, try return_body.ret(try return_body.parameter("result")));
    const clause = try c.clauseFunction(handler);
    const clause_body = try c.body(clause);
    const resumed = try clause_body.resumeValue(
        try clause_body.parameter("resumption"),
        try clause_body.parameter("environment"),
    );
    try c.define(clause, try clause_body.ret(resumed));
    return .{
        .family = family,
        .environment = environment,
        .handler = try typed.interop.handlerId(c, handler),
        .resumption = try typed.interop.schemaId(c, try typed.interop.resumptionSchema(c, handler)),
    };
}

pub fn read(b: *source.Builder, reader: Reader, capability: Id) source.Error!Id {
    return decision.ask(b, reader.family, capability, try b.constant(void, {}));
}

pub fn enter(
    b: *source.Builder,
    reader: Reader,
    body: Id,
    environment: Id,
    arguments: []const Id,
) source.Error!Id {
    return b.term(.{ .handle = .{
        .handler = reader.handler,
        .body = body,
        .arguments = arguments,
        .state = &.{environment},
    } });
}

/// This optional product is ordinary application data, not runtime scope state.
/// Instructions are in caller order followed by each lexical contribution.
pub const Layout = struct {
    schema: Id,
    instructions: Id,
    model: Id,
    models: sets.Set,
    tools: sets.Set,
    skills: sets.Set,
    memory: Id,
    override_result: Id,
};
pub const Values = struct {
    model: Id,
    instructions: Id,
    models: Id,
    tools: Id,
    skills: Id,
    memory: Id,
};
pub const Restriction = struct { instructions: Id, models: Id, tools: Id, skills: Id };
pub const Field = enum(u64) { model, instructions, models, tools, skills, memory };

pub fn layout(
    b: *source.Builder,
    instruction: Id,
    memory: Id,
    models: usize,
    tools: usize,
    skills: usize,
) source.Error!Layout {
    const model_schema = try b.scalar(u64);
    const instructions = try b.schema(.{ .seq = instruction });
    const model_set = try sets.define(b, models);
    const tool_set = try sets.define(b, tools);
    const skill_set = try sets.define(b, skills);
    const schema = try b.schema(.{ .product = &.{
        model_schema, instructions, model_set.schema, tool_set.schema, skill_set.schema, memory,
    } });
    return .{
        .schema = schema,
        .instructions = instructions,
        .model = model_schema,
        .models = model_set,
        .tools = tool_set,
        .skills = skill_set,
        .memory = memory,
        .override_result = try b.schema(.{ .sum = &.{ schema, model_schema } }),
    };
}

pub fn value(b: *source.Builder, shape: Layout, values: Values) source.Error!Id {
    return b.primitive(shape.schema, .product, &.{
        values.model, values.instructions, values.models, values.tools, values.skills, values.memory,
    }, 0);
}

pub fn field(b: *source.Builder, shape: Layout, environment: Id, selected: Field) source.Error!Id {
    const schema = switch (selected) {
        .model => shape.model,
        .instructions => shape.instructions,
        .models => shape.models.schema,
        .tools => shape.tools.schema,
        .skills => shape.skills.schema,
        .memory => shape.memory,
    };
    return b.primitive(schema, .field, &.{environment}, @backingInt(selected));
}

/// A skill/policy contribution can only restrict authority. Instructions append
/// in lexical order; memory and the selected model remain explicit caller values.
pub fn narrow(
    b: *source.Builder,
    shape: Layout,
    outer: Id,
    restriction: Restriction,
) source.Error!Id {
    const models = try b.variable(shape.models.schema);
    const tools = try b.variable(shape.tools.schema);
    const skills = try b.variable(shape.skills.schema);
    const narrowed = try value(b, shape, .{
        .model = try field(b, shape, outer, .model),
        .instructions = try b.primitive(shape.instructions, .sequence_concat, &.{
            try field(b, shape, outer, .instructions), restriction.instructions,
        }, 0),
        .models = try b.reference(models),
        .tools = try b.reference(tools),
        .skills = try b.reference(skills),
        .memory = try field(b, shape, outer, .memory),
    });
    const narrowed_models = try sets.intersection(
        b,
        shape.models,
        try field(b, shape, outer, .models),
        restriction.models,
    );
    const narrowed_tools = try sets.intersection(
        b,
        shape.tools,
        try field(b, shape, outer, .tools),
        restriction.tools,
    );
    const narrowed_skills = try sets.intersection(
        b,
        shape.skills,
        try field(b, shape, outer, .skills),
        restriction.skills,
    );
    const with_skills = try b.bind(skills, narrowed_skills, try b.pure(narrowed));
    const with_tools = try b.bind(tools, narrowed_tools, with_skills);
    return b.bind(models, narrowed_models, with_tools);
}

/// Accepted(environment) | Denied(requested_model). The caller must author its
/// denied branch. There is no host override or silent selection of another model.
pub fn overrideModel(
    b: *source.Builder,
    shape: Layout,
    environment: Id,
    model_index: usize,
) source.Error!Id {
    const selected = try b.constant(u64, model_index);
    const allowed = try b.variable(try b.scalar(bool));
    const check = try sets.member(b, shape.models, try field(b, shape, environment, .models), model_index);
    const updated = try value(b, shape, .{
        .model = selected,
        .instructions = try field(b, shape, environment, .instructions),
        .models = try field(b, shape, environment, .models),
        .tools = try field(b, shape, environment, .tools),
        .skills = try field(b, shape, environment, .skills),
        .memory = try field(b, shape, environment, .memory),
    });
    return b.bind(allowed, check, try b.term(.{ .conditional = .{
        .condition = try b.reference(allowed),
        .when_true = try b.pure(try b.primitive(shape.override_result, .variant, &.{updated}, 0)),
        .when_false = try b.pure(try b.primitive(shape.override_result, .variant, &.{selected}, 1)),
    } }));
}
