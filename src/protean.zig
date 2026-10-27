//! Public staged Protean authoring; runtime execution belongs to Kosmos.
pub const package_version = "7.0.0";
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
pub const responders = @import("responders.zig");
pub const interaction = @import("interaction.zig");
pub const inbox = @import("inbox.zig");
pub const tools = @import("tools.zig");
pub const model_invocation = @import("model_invocation.zig");
pub const adaptive_controls = @import("adaptive_controls.zig");
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
