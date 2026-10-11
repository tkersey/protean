const std = @import("std");

pub fn isAdmitted(comptime Model: type) bool {
    if (@typeInfo(Model) != .@"struct" or @typeInfo(Model).@"struct".field_names.len != 0) return false;
    inline for (.{ "name", "protocol", "model_id", "ParametersType", "parameters" }) |name| {
        if (!@hasDecl(Model, name)) return false;
        if (!@typeInfo(@TypeOf(&@field(Model, name))).pointer.attrs.@"const") return false;
    }
    return Model == Descriptor(Model.name, Model.protocol, Model.model_id, Model.parameters);
}

// Exact private-constructor identity admits factory results, not lookalikes.
// No public seal can be copied and no private declaration lookup is required.
fn Descriptor(comptime name_value: anytype, comptime protocol_value: anytype, comptime identifier: anytype, comptime parameters_value: anytype) type {
    return struct {
        pub const name = name_value;
        pub const protocol = protocol_value;
        pub const model_id = identifier;
        pub const ParametersType = @TypeOf(parameters_value);
        pub const parameters = parameters_value;
    };
}

pub const ReasoningEffort = enum {
    none,
    minimal,
    low,
    medium,
    high,
    xhigh,
    max,
};

pub const ReasoningSummary = enum {
    auto,
    concise,
    detailed,
};

fn parameterFieldAdmitted(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "max_output_tokens") or
        std.mem.eql(u8, name, "temperature") or
        std.mem.eql(u8, name, "reasoning");
}

fn modelFieldAdmitted(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "name") or
        std.mem.eql(u8, name, "protocol") or
        std.mem.eql(u8, name, "model") or
        std.mem.eql(u8, name, "parameters");
}

fn canonicalTemperature(comptime value: []const u8) bool {
    if (value.len == 0 or value[0] < '0' or value[0] > '2') return false;
    if (value.len == 1) return true;
    if (value[1] != '.' or value.len == 2 or value[value.len - 1] == '0') {
        return false;
    }
    if (value[0] == '2') return false;
    for (value[2..]) |byte| if (byte < '0' or byte > '9') return false;
    return true;
}

fn validateReasoning(comptime reasoning: anytype) void {
    if (@typeInfo(@TypeOf(reasoning)) != .@"struct") {
        @compileError("protean model reasoning configuration must be a struct");
    }
    inline for (@typeInfo(@TypeOf(reasoning)).@"struct".field_names) |field_name| {
        if (!std.mem.eql(u8, field_name, "effort") and
            !std.mem.eql(u8, field_name, "summary"))
        {
            @compileError(
                "protean model reasoning contains unsupported field '" ++
                    field_name ++ "'",
            );
        }
    }
    if (!@hasField(@TypeOf(reasoning), "effort") and
        !@hasField(@TypeOf(reasoning), "summary"))
    {
        @compileError("protean model reasoning configuration must not be empty");
    }
    if (@hasField(@TypeOf(reasoning), "effort")) {
        const effort: ReasoningEffort = reasoning.effort;
        _ = effort;
    }
    if (@hasField(@TypeOf(reasoning), "summary")) {
        const summary: ReasoningSummary = reasoning.summary;
        _ = summary;
    }
}

fn validateParameters(comptime parameters: anytype) void {
    if (@TypeOf(parameters) == void) return;
    inline for (@typeInfo(@TypeOf(parameters)).@"struct".field_names) |field_name| {
        if (!parameterFieldAdmitted(field_name)) {
            @compileError("protean model parameters contain unsupported field '" ++ field_name ++ "'");
        }
    }
    if (@hasField(@TypeOf(parameters), "max_output_tokens")) {
        if (@TypeOf(parameters.max_output_tokens) != u32) {
            @compileError("protean model max_output_tokens must be u32");
        }
        if (parameters.max_output_tokens == 0) {
            @compileError("protean model max_output_tokens must be positive");
        }
    }
    if (@hasField(@TypeOf(parameters), "temperature")) {
        const value: []const u8 = parameters.temperature;
        if (!canonicalTemperature(value)) {
            @compileError("protean model temperature must be a canonical decimal from 0 through 2");
        }
    }
    if (@hasField(@TypeOf(parameters), "reasoning")) {
        validateReasoning(parameters.reasoning);
    }
}

pub fn model(comptime spec: anytype) type {
    inline for (@typeInfo(@TypeOf(spec)).@"struct".field_names) |field_name| {
        if (!modelFieldAdmitted(field_name)) {
            @compileError("protean.model unknown source field '" ++ field_name ++ "'");
        }
    }
    if (!@hasField(@TypeOf(spec), "name") or
        !@hasField(@TypeOf(spec), "protocol") or
        !@hasField(@TypeOf(spec), "model"))
    {
        @compileError("protean.model requires name, protocol, and model");
    }
    if (spec.name.len == 0) @compileError("protean model name must not be empty");
    if (spec.model.len == 0) @compileError("protean model identifier must not be empty");
    const Protocol = spec.protocol;
    if (!@hasDecl(Protocol, "semantic_identity") or Protocol.semantic_identity.len == 0) {
        @compileError("protean model protocol requires a semantic_identity");
    }
    const Parameters = if (@hasField(@TypeOf(spec), "parameters"))
        @TypeOf(spec.parameters)
    else
        void;
    const parameters_value: Parameters = if (@hasField(@TypeOf(spec), "parameters"))
        spec.parameters
    else {};
    comptime validateParameters(parameters_value);
    return Descriptor(spec.name, Protocol, spec.model, parameters_value);
}

pub fn validateUnique(comptime models: anytype) void {
    if (models.len == 0) @compileError("protean system requires at least one model");
    inline for (models, 0..) |Model, index| {
        if (!isAdmitted(Model)) {
            @compileError("protean system model must be constructed by protean.model");
        }
        _ = Model.protocol.semantic_identity;
        inline for (models, 0..) |Earlier, earlier_index| {
            if (earlier_index < index and std.mem.eql(u8, Earlier.name, Model.name)) {
                @compileError("protean model semantic name is duplicated");
            }
        }
    }
}
