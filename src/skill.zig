const std = @import("std");
const prompt = @import("prompt.zig");

pub const Activation = enum { always, conditional, explicit };
pub const RenderPosition = enum { before_user, after_user };
pub fn isAdmitted(comptime Skill: type) bool {
    if (@typeInfo(Skill) != .@"struct" or @typeInfo(Skill).@"struct".field_names.len != 0) return false;
    inline for (.{ "id", "description", "instructions", "role", "position", "activation", "actions" }) |name| {
        if (!@hasDecl(Skill, name)) return false;
        if (!@typeInfo(@TypeOf(&@field(Skill, name))).pointer.attrs.@"const") return false;
    }
    return Skill == Descriptor(Skill.id, Skill.description, Skill.instructions, Skill.role, Skill.position, Skill.activation, Skill.actions);
}

fn Descriptor(comptime id_value: anytype, comptime description_value: anytype, comptime instructions_value: anytype, comptime role_value: anytype, comptime position_value: anytype, comptime activation_value: anytype, comptime actions_value: anytype) type {
    return struct {
        pub const id = id_value;
        pub const description = description_value;
        pub const instructions = instructions_value;
        pub const role = role_value;
        pub const position = position_value;
        pub const activation = activation_value;
        pub const actions = actions_value;
    };
}

pub fn skill(comptime spec: anytype) type {
    if (!@hasField(@TypeOf(spec), "id") or
        !@hasField(@TypeOf(spec), "description") or
        !@hasField(@TypeOf(spec), "instructions") or
        !@hasField(@TypeOf(spec), "role") or
        !@hasField(@TypeOf(spec), "position") or
        !@hasField(@TypeOf(spec), "activation") or
        !@hasField(@TypeOf(spec), "actions"))
    {
        @compileError("protean.skill requires id, description, instructions, role, position, activation, and actions");
    }
    inline for (@typeInfo(@TypeOf(spec)).@"struct".field_names) |field_name| {
        if (!std.mem.eql(u8, field_name, "id") and
            !std.mem.eql(u8, field_name, "description") and
            !std.mem.eql(u8, field_name, "instructions") and
            !std.mem.eql(u8, field_name, "role") and
            !std.mem.eql(u8, field_name, "position") and
            !std.mem.eql(u8, field_name, "activation") and
            !std.mem.eql(u8, field_name, "actions"))
        {
            @compileError("protean.skill unknown source field '" ++ field_name ++ "'");
        }
    }
    const activation_value: Activation = spec.activation;
    const role_value: prompt.Role = spec.role;
    const position_value: RenderPosition = spec.position;
    if (spec.id.len == 0 or spec.description.len == 0 or spec.instructions.len == 0) {
        @compileError("protean skill identity and content must not be empty");
    }
    return Descriptor(spec.id, spec.description, spec.instructions, role_value, position_value, activation_value, spec.actions);
}

pub fn validateUnique(comptime skills: anytype) void {
    inline for (skills, 0..) |Skill, index| {
        inline for (skills, 0..) |Earlier, earlier_index| {
            if (earlier_index < index and std.mem.eql(u8, Earlier.id, Skill.id)) {
                @compileError("protean skill semantic id is duplicated");
            }
        }
    }
}
