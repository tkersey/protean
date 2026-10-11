const std = @import("std");

pub const Role = enum { system, developer, user };
pub fn isAdmitted(comptime Prompt: type) bool {
    if (@typeInfo(Prompt) != .@"struct" or @typeInfo(Prompt).@"struct".field_names.len != 0) return false;
    inline for (.{ "prompt_role", "content" }) |name| {
        if (!@hasDecl(Prompt, name)) return false;
        if (!@typeInfo(@TypeOf(&@field(Prompt, name))).pointer.attrs.@"const") return false;
    }
    return Prompt == Descriptor(Prompt.prompt_role, Prompt.content);
}

fn Descriptor(comptime role_value: anytype, comptime content_value: anytype) type {
    return struct {
        pub const prompt_role = role_value;
        pub const content = content_value;
    };
}

pub fn literal(comptime spec: anytype) type {
    if (!@hasField(@TypeOf(spec), "role") or
        !@hasField(@TypeOf(spec), "content"))
    {
        @compileError("protean.prompt.literal requires role and content");
    }
    inline for (@typeInfo(@TypeOf(spec)).@"struct".field_names) |field_name| {
        if (!std.mem.eql(u8, field_name, "role") and
            !std.mem.eql(u8, field_name, "content"))
        {
            @compileError("protean.prompt.literal unknown source field '" ++ field_name ++ "'");
        }
    }
    const role: Role = spec.role;
    if (spec.content.len == 0) @compileError("protean prompt content must not be empty");
    return Descriptor(role, spec.content);
}
