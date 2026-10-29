//! Structural ingestion boundary for untrusted existing Horos records.
//! It supplies bounded catalogs to the ordinary source checker and reuses the
//! Horos declaration/instruction validators for records that may be unused.
const std = @import("std");
const horos = @import("horos");
const data = @import("horos_data");
const p = data.program;
const source = horos.source;
const Error = source.Error;

fn reference(id: u64, length: usize) Error!void {
    if (id >= length) return error.InvalidReference;
}
fn references(ids: []const u64, length: usize) Error!void {
    for (ids) |id| try reference(id, length);
}
fn optional(id: ?u64, length: usize) Error!void {
    if (id) |v| try reference(v, length);
}
fn region(id: u64, count: u64) Error!void {
    if (id >= count) return error.InvalidReference;
}

pub fn validate(a: std.mem.Allocator, m: source.Module, diagnostic: *source.Diagnostic) Error!void {
    diagnostic.* = .{ .phase = .source_check };
    return validateBody(a, m, diagnostic) catch |err| {
        diagnostic.code = err;
        return err;
    };
}

fn validateBody(a: std.mem.Allocator, m: source.Module, diagnostic: *source.Diagnostic) Error!void {
    try reference(m.entry, m.functions.len);
    try reference(m.failure, m.schemas.len);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const facts = try data.admission.schemas(scratch, m.schemas);
    for (m.constants) |literal| try data.admission.value(scratch, m.schemas, facts, literal);
    try references(m.variables, m.schemas.len);
    const functions = try functionDeclarations(scratch, m, diagnostic);
    for (m.effects) |effect| {
        try reference(effect.payload, m.schemas.len);
        try reference(effect.result, m.schemas.len);
        try references(effect.bodies, m.schemas.len);
        try references(effect.use_site_effects, m.effects.len);
    }
    const handlers = try handlerDeclarations(scratch, m);
    const declarations: data.activation.Program = .{
        .roots = p.Roots{
            .entry = m.entry,
            .result = m.functions[@intCast(m.entry)].result,
            .failure = m.failure,
        },
        .schemas = m.schemas,
        .constants = m.constants,
        .effects = m.effects,
        .functions = functions,
        .handlers = handlers,
        .scopes = p.ScopeCatalog{ .region_count = m.region_count, .resources = m.resources },
        .constructors = @as([]const p.Constructor, &.{}),
        .blocks = @as([]const data.activation.Block, &.{}),
    };
    const uses = try data.contracts.validateDiagnosed(scratch, declarations, &diagnostic.target);
    try validateValues(scratch, m, diagnostic, declarations, uses);
    try validateTerms(m, diagnostic);
}

fn functionDeclarations(
    a: std.mem.Allocator,
    m: source.Module,
    diagnostic: *source.Diagnostic,
) Error![]data.activation.Function {
    const functions = try a.alloc(data.activation.Function, m.functions.len);
    for (m.functions, functions, 0..) |function, *target, id| {
        diagnostic.function = id;
        try references(function.parameters, m.variables.len);
        try reference(function.result, m.schemas.len);
        try references(function.effects, m.effects.len);
        for (function.regions) |id_region| try region(id_region, m.region_count);
        try reference(function.body orelse return error.UndefinedFunction, m.terms.len);
        // A declaration-only view for Horos's intrinsic contract validator.
        // This is never an executable image and has no lowered control flow.
        target.* = .{
            .entry = 0,
            .inputs = function.parameters,
            .layout = .{ .slots = m.variables },
            .result = function.result,
            .effects = function.effects,
            .regions = function.regions,
        };
    }
    diagnostic.function = null;
    return functions;
}

fn handlerDeclarations(a: std.mem.Allocator, m: source.Module) Error![]data.activation.Handler {
    const handlers = try a.alloc(data.activation.Handler, m.handlers.len);
    for (m.handlers, handlers) |handler, *target| {
        const clauses = try a.alloc(data.activation.Clause, handler.clauses.len);
        for (handler.clauses, clauses) |clause, *out| out.* = .{
            .effect = clause.effect,
            .function = clause.function,
            .resumption = clause.resumption,
        };
        target.* = .{
            .mode = handler.mode,
            .input = handler.input,
            .answer = handler.answer,
            .return_function = handler.return_function,
            .clauses = clauses,
            .state = handler.state,
            .effects = handler.effects,
        };
    }
    return handlers;
}

fn validateValues(
    a: std.mem.Allocator,
    m: source.Module,
    diagnostic: *source.Diagnostic,
    declarations: data.activation.Program,
    uses: anytype,
) Error!void {
    const slots = try a.alloc(u64, m.values.len);
    for (m.values, slots, 0..) |value, *slot, id| {
        diagnostic.value = id;
        try reference(value.schema, m.schemas.len);
        slot.* = value.schema;
        switch (value.expression) {
            .variable => |variable| {
                try reference(variable, m.variables.len);
                if (m.variables[@intCast(variable)] != value.schema) return error.TypeMismatch;
            },
            .literal => |literal| {
                try reference(literal, m.constants.len);
                if (m.constants[
                    @intCast(literal)
                ].schema != value.schema) return error.TypeMismatch;
            },
            .lambda => try validateLambda(m, value, declarations),
            .primitive => try validatePrimitive(m, value, id, declarations, slots, uses),
        }
    }
    diagnostic.value = null;
}

fn validateTerms(m: source.Module, diagnostic: *source.Diagnostic) Error!void {
    for (m.terms, 0..) |term, id| {
        diagnostic.term = id;
        switch (term) {
            .value, .dispose, .fail => |value| try reference(value, m.values.len),
            .yield_then => |next| try reference(next, id),
            .bind => |v| {
                try reference(v.variable, m.variables.len);
                try references(&.{ v.value, v.next }, id);
            },
            .conditional => |v| {
                try reference(v.condition, m.values.len);
                try references(&.{ v.when_true, v.when_false }, id);
            },
            .call => |v| {
                try reference(v.function, m.functions.len);
                try references(v.arguments, m.values.len);
            },
            .apply => |v| {
                try reference(v.computation, m.values.len);
                try references(v.arguments, m.values.len);
            },
            .perform => |v| {
                try reference(v.effect, m.effects.len);
                try optional(v.capability, m.values.len);
                try reference(v.payload, m.values.len);
                try references(v.bodies, m.values.len);
                try references(v.use_site_capabilities, m.values.len);
            },
            .handle => |v| {
                try reference(v.handler, m.handlers.len);
                try reference(v.body, m.values.len);
                try references(v.arguments, m.values.len);
                try references(v.state, m.values.len);
            },
            .resume_value => |v| try references(&.{ v.resumption, v.argument }, m.values.len),
            .resume_with => |v| {
                try references(&.{ v.resumption, v.argument }, m.values.len);
                try reference(v.handler, m.handlers.len);
                try references(v.state, m.values.len);
            },
            .resume_computation => |v| try references(
                &.{ v.resumption, v.computation },
                m.values.len,
            ),
            .protect => |v| try validateProtection(m, v),
            .with_region => |v| {
                try region(v.region, m.region_count);
                try reference(v.body, m.values.len);
                try references(v.arguments, m.values.len);
            },
            .match_sum => |v| {
                try reference(v.value, m.values.len);
                for (v.cases) |case| {
                    try reference(case.variable, m.variables.len);
                    try reference(case.body, id);
                }
            },
            .unpack_product => |v| {
                try reference(v.value, m.values.len);
                try references(v.variables, m.variables.len);
                try reference(v.body, id);
            },
        }
    }
    diagnostic.term = null;
}

fn validateLambda(
    m: source.Module,
    value: source.ast.Value,
    declarations: data.activation.Program,
) Error!void {
    const function = value.expression.lambda;
    try reference(function, m.functions.len);
    const signature = try data.contracts.computation(declarations, value.schema);
    const f = m.functions[@intCast(function)];
    if (signature.parameters.len != f.parameters.len or
        signature.result != f.result or
        !std.mem.eql(
            u64,
            signature.regions,
            f.regions,
        )) return error.TypeMismatch;
    for (signature.parameters, f.parameters) |wanted, variable| if (wanted != m.variables[
        @intCast(variable)
    ]) return error.TypeMismatch;
    try data.contracts.subset(f.effects, signature.effects);
}

fn validatePrimitive(
    m: source.Module,
    value: source.ast.Value,
    id: usize,
    declarations: data.activation.Program,
    slots: []const u64,
    uses: anytype,
) Error!void {
    const primitive = value.expression.primitive;
    // Structural dependencies are acyclic; function/schema recursion
    // does not pass through these operand IDs and remains legal.
    try references(primitive.operands, id);
    if (primitive.opcode == .computation) {
        _ = try data.contracts.computation(declarations, value.schema);
        if (primitive.failures.len != 0) return error.InvalidProgram;
        return;
    }
    var owner = m.entry;
    if (primitive.opcode == .resource_pack or primitive.opcode == .resource_unpack) {
        if (primitive.operands.len != 1) return error.InvalidProgram;
        var resource_schema = if (primitive.opcode == .resource_pack) value.schema else slots[
            @intCast(primitive.operands[0])
        ];
        var shape = m.schemas[@intCast(resource_schema)];
        if (shape == .internal and shape.internal == .borrowed) {
            resource_schema = shape.internal.borrowed.value;
            shape = m.schemas[@intCast(resource_schema)];
        }
        if (shape != .internal or
            shape.internal != .abstract_resource)
            return error.TypeMismatch;
        const resource = m.resources[@intCast(shape.internal.abstract_resource)];
        const authorities = if (primitive.opcode == .resource_pack)
            resource.introducers
        else
            resource.eliminators;
        if (authorities.len == 0) return error.InvalidOwnership;
        // Intrinsic type validity only. The actual containing
        // function's authority is checked again by target admission.
        owner = authorities[0];
    }
    try data.admission.validateInstruction(declarations, owner, .{
        .opcode = primitive.opcode,
        .result_type = value.schema,
        .operands = primitive.operands,
        .immediate = primitive.immediate,
        .failures = primitive.failures,
    }, slots[0..id], uses);
}

fn validateProtection(m: source.Module, v: @FieldType(source.ast.Term, "protect")) Error!void {
    try references(&.{ v.body, v.cleanup }, m.values.len);
    try references(v.arguments, m.values.len);
    try optional(v.resource, m.values.len);
    if (v.loan_region) |loan| try region(loan, m.region_count);
}
