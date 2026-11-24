const std = @import("std");
const adaptive = @import("definition");
const t = @import("application_types");

const Study = struct {
    pub const System = adaptive.System;
    pub const ControllerSystem = adaptive.StudyControllerSystem;
    pub const capabilities = adaptive.capabilities;
    pub const resources = adaptive.resources;
    pub const generatedResources = adaptive.generatedResources;
    pub const support_types = t.support_types ++ .{
        .{ .name = "StudyBindings", .T = t.StudyBindings },
        .{ .name = "StudyWorkspaceRequest", .T = t.StudyWorkspaceRequest },
    };
};

pub fn main(init: std.process.Init) !void {
    return @import("emitter").write(Study, t, init);
}
