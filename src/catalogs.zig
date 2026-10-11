//! Author-time catalogs installed before application.emit. Entries refer only
//! to ordinary Horos schemas, constants, values, functions, and effects.
//! They are neither runtime registries nor a separate control representation.
const std = @import("std");
const horos = @import("horos");
const contracts = @import("protean_contracts");
const models = @import("model.zig");
const prompts = @import("prompt.zig");
const skills = @import("skill.zig");
const tool_library = @import("tools.zig");
const interaction_library = @import("interaction.zig");
const Id = horos.source.Id;

pub const Reasoning = struct { effort: ?models.ReasoningEffort, summary: ?models.ReasoningSummary };
pub const Parameters = struct {
    max_output_tokens: ?u32,
    temperature: ?contracts.Utf8,
    reasoning: ?Reasoning,
};
pub const ModelValue = struct {
    protocol: contracts.Utf8,
    model: contracts.Utf8,
    parameters: Parameters,
};
pub const PromptValue = struct { role: prompts.Role, content: contracts.Utf8 };
pub const SkillValue = struct {
    id: contracts.Utf8,
    description: contracts.Utf8,
    instructions: contracts.Utf8,
    role: prompts.Role,
    position: skills.RenderPosition,
    activation: skills.Activation,
    tools: []const u64,
};

pub const Model = struct {
    name: []const u8,
    schema: Id,
    value: Id,
    protocol: Id,
    model_id: Id,
    parameters: Id,
};
pub const Prompt = struct { schema: Id, value: Id, role: Id, content: Id };
pub const Skill = struct {
    name: []const u8,
    schema: Id,
    value: Id,
    description: Id,
    instructions: Id,
    role: Id,
    position: Id,
    activation: Id,
    tools: Id,
};

/// All slices live until the authoring Context's Builder is deinitialized.
/// Prompt order and skill/tool ordinals preserve the supplied declaration order.
pub const Catalogs = struct {
    models: []const Model = &.{},
    prompts: []const Prompt = &.{},
    skills: []const Skill = &.{},
    tools: []const tool_library.Descriptor = &.{},
    interactions: []const interaction_library.Definition = &.{},

    pub fn model(self: Catalogs, name: []const u8) !Model {
        for (self.models) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;
        return error.UnknownModel;
    }

    pub fn prompt(self: Catalogs, ordinal: usize) !Prompt {
        if (ordinal >= self.prompts.len) return error.UnknownPrompt;
        return self.prompts[ordinal];
    }

    pub fn skill(self: Catalogs, name: []const u8) !Skill {
        for (self.skills) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;
        return error.UnknownSkill;
    }

    pub fn tool(self: Catalogs, identity_or_name: []const u8) !tool_library.Descriptor {
        return self.tools[try toolIndex(self.tools, identity_or_name)];
    }

    pub fn interaction(self: Catalogs, name: []const u8) !interaction_library.Definition {
        for (self.interactions) |entry| {
            if (std.mem.eql(u8, entry.contract.name, name)) return entry;
        }
        return error.UnknownInteraction;
    }
};

pub const SourceIssue = enum {
    InvalidSystemSource,
    UnknownSystemField,
    InvalidCatalogList,
    UnsupportedModelDescriptor,
    UnsupportedPromptDescriptor,
    UnsupportedSkillDescriptor,
    UnsupportedDeclarationType,
    RuntimeCallbackDescriptor,
    DuplicateModelName,
    DuplicateSkillName,
    InvalidDescriptorText,
    InvalidSkillToolReference,
    UnsupportedModelProtocol,
};

/// This exact check is called by protean.system. Lists are tuples or arrays of
/// descriptor types. Runtime values/function pointers are not declarations.
pub fn sourceIssue(comptime spec: anytype) ?SourceIssue {
    if (@typeInfo(@TypeOf(spec)) != .@"struct") return .InvalidSystemSource;
    inline for (@typeInfo(@TypeOf(spec)).@"struct".field_names) |entry_field_name| {
        const names = .{ "InitialArgs", "Result", "Failure", "application", "models", "prompts", "skills", "tools", "interactions" };
        var known = false;
        inline for (names) |name| known = known or std.mem.eql(u8, name, entry_field_name);
        if (!known) return .UnknownSystemField;
    }
    inline for (.{ "models", "prompts", "skills", "tools", "interactions" }) |name| {
        if (@hasField(@TypeOf(spec), name)) {
            const entries = @field(spec, name);
            if (comptime !isList(@TypeOf(entries))) return .InvalidCatalogList;
            if (listIssue(name, entries)) |issue| return issue;
        }
    }
    return null;
}

fn isList(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.is_tuple,
        .array => true,
        else => false,
    };
}

fn listIssue(comptime kind: []const u8, comptime entries: anytype) ?SourceIssue {
    inline for (entries, 0..) |Entry, index| {
        if (comptime entryIssue(kind, Entry)) |issue| return issue;
        if (comptime std.mem.eql(u8, kind, "models")) {
            inline for (entries, 0..) |Earlier, previous| {
                if (previous < index and std.mem.eql(u8, Entry.name, Earlier.name))
                    return .DuplicateModelName;
            }
        }
        if (comptime std.mem.eql(u8, kind, "skills")) {
            inline for (entries, 0..) |Earlier, previous| {
                if (previous < index and std.mem.eql(u8, Entry.id, Earlier.id))
                    return .DuplicateSkillName;
            }
        }
    }
    return null;
}

fn entryIssue(comptime kind: []const u8, comptime Entry: anytype) ?SourceIssue {
    if (@TypeOf(Entry) != type) return .UnsupportedDeclarationType;
    if (@typeInfo(Entry) != .@"struct") return .UnsupportedDeclarationType;
    if (comptime std.mem.eql(u8, kind, "models")) {
        if (!models.isAdmitted(Entry)) return .UnsupportedModelDescriptor;
        if (!text(Entry.name) or !text(Entry.model_id)) return .InvalidDescriptorText;
        if (!std.mem.eql(u8, Entry.protocol.semantic_identity, @import("protocol/openai_responses_v2.zig").semantic_identity))
            return .UnsupportedModelProtocol;
    } else if (comptime std.mem.eql(u8, kind, "prompts")) {
        if (!prompts.isAdmitted(Entry)) return .UnsupportedPromptDescriptor;
        if (!text(Entry.content)) return .InvalidDescriptorText;
    } else if (comptime std.mem.eql(u8, kind, "skills")) {
        if (!skills.isAdmitted(Entry)) return .UnsupportedSkillDescriptor;
        if (!text(Entry.id) or !text(Entry.instructions) or !text(Entry.description))
            return .InvalidDescriptorText;
        if (!isList(@TypeOf(Entry.actions))) return .InvalidCatalogList;
        inline for (Entry.actions) |name| {
            if (comptime !stringType(@TypeOf(name))) return .InvalidSkillToolReference;
            const action_name: []const u8 = name;
            if (!text(action_name)) return .InvalidDescriptorText;
        }
    } else {
        if (@typeInfo(Entry).@"struct".field_names.len != 0) return .RuntimeCallbackDescriptor;
        if (!@hasDecl(Entry, "declare")) return .UnsupportedDeclarationType;
        if (@typeInfo(@TypeOf(Entry.declare)) != .@"fn") return .RuntimeCallbackDescriptor;
    }
    return null;
}

fn stringType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child == u8,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

fn text(value: []const u8) bool {
    return value.len != 0 and std.unicode.utf8ValidateSlice(value);
}

/// Tool declaration types implement `declare(Context) !tools.Descriptor`;
/// interaction types implement `declare(Context) !interaction.Definition`.
/// These functions run once at authoring. They cannot install native runtime
/// callbacks because their returned representations contain source IDs only.
pub fn install(context: anytype, comptime spec: anytype) !Catalogs {
    var result: Catalogs = .{};
    if (@hasField(@TypeOf(spec), "models")) result.models = try installModels(context, spec.models);
    if (@hasField(@TypeOf(spec), "prompts")) result.prompts = try installPrompts(context, spec.prompts);
    var updated = context;
    updated.catalogs = result;
    if (@hasField(@TypeOf(spec), "tools")) result.tools = try installTools(updated, spec.tools);
    updated.catalogs = result;
    if (@hasField(@TypeOf(spec), "interactions"))
        result.interactions = try installInteractions(updated, spec.interactions);
    updated.catalogs = result;
    if (@hasField(@TypeOf(spec), "skills")) result.skills = try installSkills(updated, spec.skills);
    return result;
}

fn literal(c: anytype, comptime T: type, value: T) !Id {
    return c.literal(T, value);
}

fn projectField(c: anytype, comptime T: type, value: Id, ordinal: Id) !Id {
    return c.builder.primitive(try c.schema(T), .field, &.{value}, ordinal);
}

fn installModels(c: anytype, comptime entries: anytype) ![]const Model {
    const result = try c.builder.allocator().alloc(Model, entries.len);
    inline for (entries, 0..) |Entry, index| {
        const destination = &result[index];
        const value = try literal(c, ModelValue, .{
            .protocol = .{ .bytes = Entry.protocol.semantic_identity },
            .model = .{ .bytes = Entry.model_id },
            .parameters = modelParameters(Entry),
        });
        destination.* = .{
            .name = Entry.name,
            .schema = try c.schema(ModelValue),
            .value = value,
            .protocol = try projectField(c, contracts.Utf8, value, 0),
            .model_id = try projectField(c, contracts.Utf8, value, 1),
            .parameters = try projectField(c, Parameters, value, 2),
        };
    }
    return result;
}

fn modelParameters(comptime ModelType: type) Parameters {
    const p = ModelType.parameters;
    const has = @TypeOf(p) != void;
    return .{
        .max_output_tokens = if (has and @hasField(@TypeOf(p), "max_output_tokens"))
            p.max_output_tokens
        else
            null,
        .temperature = if (has and @hasField(@TypeOf(p), "temperature"))
            .{ .bytes = p.temperature }
        else
            null,
        .reasoning = if (has and @hasField(@TypeOf(p), "reasoning")) .{
            .effort = if (@hasField(@TypeOf(p.reasoning), "effort")) p.reasoning.effort else null,
            .summary = if (@hasField(@TypeOf(p.reasoning), "summary")) p.reasoning.summary else null,
        } else null,
    };
}

fn installPrompts(c: anytype, comptime entries: anytype) ![]const Prompt {
    const result = try c.builder.allocator().alloc(Prompt, entries.len);
    inline for (entries, 0..) |Entry, index| {
        const destination = &result[index];
        const value = try literal(c, PromptValue, .{
            .role = Entry.prompt_role,
            .content = .{ .bytes = Entry.content },
        });
        destination.* = .{
            .schema = try c.schema(PromptValue),
            .value = value,
            .role = try projectField(c, prompts.Role, value, 0),
            .content = try projectField(c, contracts.Utf8, value, 1),
        };
    }
    return result;
}

fn installTools(c: anytype, comptime entries: anytype) ![]const tool_library.Descriptor {
    const result = try c.builder.allocator().alloc(tool_library.Descriptor, entries.len);
    inline for (entries, 0..) |Entry, index| result[index] = try Entry.declare(c);
    for (result) |entry| {
        if (!text(entry.identity) or !std.unicode.utf8ValidateSlice(entry.name) or
            !std.unicode.utf8ValidateSlice(entry.description)) return error.InvalidDescriptorText;
    }
    try tool_library.validate(c, result);
    // Identity and visible-name aliases must resolve to one declaration only.
    for (result, 0..) |entry, index| {
        for (result[0..index]) |earlier| {
            if ((entry.name.len != 0 and std.mem.eql(u8, entry.name, earlier.identity)) or
                (earlier.name.len != 0 and std.mem.eql(u8, entry.identity, earlier.name)) or
                (entry.name.len != 0 and std.mem.eql(u8, entry.name, earlier.name)))
                return error.AmbiguousToolReference;
        }
    }
    return result;
}

fn installInteractions(c: anytype, comptime entries: anytype) ![]const interaction_library.Definition {
    const result = try c.builder.allocator().alloc(interaction_library.Definition, entries.len);
    inline for (entries, 0..) |Entry, index| result[index] = try Entry.declare(c);
    for (result, 0..) |entry, index| {
        const canonical = try interaction_library.define(c.builder, entry.contract);
        if (!std.meta.eql(canonical, entry)) return error.InvalidInteractionDeclaration;
        for (result[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.contract.name, entry.contract.name))
                return error.DuplicateInteractionName;
        }
        try c.registry.classify(entry.effect, .interaction);
    }
    return result;
}

fn installSkills(c: anytype, comptime entries: anytype) ![]const Skill {
    const result = try c.builder.allocator().alloc(Skill, entries.len);
    inline for (entries, 0..) |Entry, ordinal| {
        const destination = &result[ordinal];
        const references = try c.builder.allocator().alloc(u64, Entry.actions.len);
        inline for (Entry.actions, 0..) |name, index| {
            const target = &references[index];
            target.* = try toolIndex(c.catalogs.tools, name);
            for (references[0..index]) |earlier| {
                if (earlier == target.*) return error.DuplicateSkillTool;
            }
        }
        const value = try literal(c, SkillValue, .{
            .id = .{ .bytes = Entry.id },
            .description = .{ .bytes = Entry.description },
            .instructions = .{ .bytes = Entry.instructions },
            .role = Entry.role,
            .position = Entry.position,
            .activation = Entry.activation,
            .tools = references,
        });
        destination.* = .{
            .name = Entry.id,
            .schema = try c.schema(SkillValue),
            .value = value,
            .description = try projectField(c, contracts.Utf8, value, 1),
            .instructions = try projectField(c, contracts.Utf8, value, 2),
            .role = try projectField(c, prompts.Role, value, 3),
            .position = try projectField(c, skills.RenderPosition, value, 4),
            .activation = try projectField(c, skills.Activation, value, 5),
            .tools = try projectField(c, []const u64, value, 6),
        };
    }
    return result;
}

fn toolIndex(entries: []const tool_library.Descriptor, name: []const u8) !usize {
    var found: ?usize = null;
    for (entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.identity, name) or
            (entry.name.len != 0 and std.mem.eql(u8, entry.name, name)))
        {
            if (found != null) return error.AmbiguousToolReference;
            found = index;
        }
    }
    return found orelse error.UnknownSkillTool;
}
