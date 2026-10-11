//! Public staged Protean authoring; runtime execution belongs to Kronos.
pub const package_version = "4.0.0-dev.0";
pub const Context = @import("authoring.zig").Context;
pub const system = @import("authoring.zig").system;
pub const compile = @import("authoring.zig").compile;
pub const compileObserved = @import("authoring.zig").compileObserved;
pub const CompileStage = @import("authoring.zig").CompileStage;
pub const CompileOptions = @import("authoring.zig").CompileOptions;
pub const contracts = @import("protean_contracts");
pub const admission = @import("admission.zig");
pub const catalogs = @import("catalogs.zig");
pub const callable = @import("callable.zig");
pub const participant = @import("participant.zig");
pub const observation = @import("observation.zig");
pub const responders = @import("responders.zig");
pub const decision = @import("decision.zig");
pub const interaction = @import("interaction.zig");
pub const inbox = @import("inbox.zig");
pub const scopes = @import("scopes.zig");
pub const sets = @import("sets.zig");
pub const approval = @import("approval.zig");
pub const tools = @import("tools.zig");
pub const deliberation = @import("deliberation.zig");
pub const clarification = @import("clarification.zig");
pub const value_equality = @import("value_equality.zig");
pub const model_invocation = @import("model_invocation.zig");
pub const adaptive_controls = @import("adaptive_controls.zig");
pub const conversation = @import("conversation.zig");
pub const react = @import("react.zig");
pub const model = @import("model.zig").model;
pub const prompt = @import("prompt.zig");
pub const skill = @import("skill.zig").skill;

comptime {
    const horos = @import("horos");
    if (!@hasDecl(horos, "source") or !@hasDecl(horos, "data") or
        !@hasDecl(horos, "program") or !@hasDecl(horos.program, "compileObserved") or
        !@hasField(horos.source.Compiled, "flow"))
        @compileError("Protean requires the coordinated Horos stable-activation compiler and data API");
}
