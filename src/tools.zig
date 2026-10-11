//! One declaration owns each tool's wire schema, implementation, model metadata,
//! and role. Declaration bodies are staged Horos functions, never callbacks.
const std = @import("std");
const source = @import("horos").source;
const authoring = @import("authoring.zig");
const admission = @import("admission.zig");
pub const Id = source.Id;
pub const Compiled = @import("compiled_tool.zig").Specification;
pub const declareCompiled = @import("compiled_tool.zig").declare;
pub const textInspection = @import("text_inspection.zig");

pub const Implementation = union(enum) { external: Id, local: Id };
pub const Descriptor = struct {
    identity: []const u8,
    payload: Id,
    result: Id,
    implementation: Implementation,
    role: admission.Role,
    model_offered: bool = false,
    name: []const u8 = "",
    description: []const u8 = "",
};

pub fn validate(c: authoring.Context, catalog: []const Descriptor) !void {
    for (catalog, 0..) |tool, index| {
        if (tool.identity.len == 0) return error.InvalidToolDeclaration;
        if (tool.model_offered and (tool.name.len == 0 or tool.description.len == 0))
            return error.InvalidToolDeclaration;
        if (tool.payload >= c.builder.schemas.items.len or
            tool.result >= c.builder.schemas.items.len) return error.InvalidToolDeclaration;
        for (catalog[0..index]) |prior| {
            if (std.mem.eql(u8, prior.identity, tool.identity) or
                (tool.model_offered and prior.model_offered and
                    std.mem.eql(u8, prior.name, tool.name))) return error.DuplicateToolDeclaration;
        }
        switch (tool.implementation) {
            .external => |effect| {
                if (effect >= c.builder.effects.items.len) return error.InvalidToolDeclaration;
                const declared = c.builder.effects.items[@intCast(effect)];
                if (!declared.external or declared.payload != tool.payload or
                    declared.result != tool.result or
                    !std.mem.eql(u8, declared.identity, tool.identity))
                    return error.InvalidToolDeclaration;
                try c.registry.classify(effect, tool.role);
            },
            .local => |function| {
                if (function >= c.builder.functions.items.len) return error.InvalidToolDeclaration;
                const declared = c.builder.functions.items[@intCast(function)];
                if (declared.parameters.len != 1 or declared.result != tool.result or
                    c.builder.variables.items[@intCast(declared.parameters[0])] != tool.payload)
                    return error.InvalidToolDeclaration;
                if (tool.role == .commit or tool.role == .write or tool.role == .approval)
                    return error.ProtectedToolRequiresCheckedOwner;
            },
        }
    }
}

/// Direct runtime-only/read operations are ordinary staged calls. Operations
/// bearing commit, write, or approval authority use their checked composition.
pub fn perform(c: authoring.Context, tool: Descriptor, payload: Id) !Id {
    try validate(c, &.{tool});
    if (tool.role == .commit or tool.role == .write or tool.role == .approval)
        return error.ProtectedToolRequiresCheckedOwner;
    return switch (tool.implementation) {
        .external => |effect| c.builder.term(.{ .perform = .{
            .effect = effect,
            .payload = payload,
        } }),
        .local => |function| c.builder.term(.{ .call = .{
            .function = function,
            .arguments = &.{payload},
        } }),
    };
}

/// Live and hypothetical observations have different in-image tags. A model
/// proposal is distinct again; none can become a live observation by text labels.
pub fn Observation(comptime Value: type) type {
    return union(enum) { external: Value, simulation: Value, proposal: Value };
}

/// Every delivery status is explicit. An uncertain operation is never a request
/// to restore an approval grant or retry a possibly completed environmental write.
pub fn CommitResult(
    comptime Success: type,
    comptime Conflict: type,
    comptime Failure: type,
    comptime Uncertain: type,
) type {
    return union(enum) {
        success: Success,
        conflict: Conflict,
        failure: Failure,
        uncertain: Uncertain,
    };
}
