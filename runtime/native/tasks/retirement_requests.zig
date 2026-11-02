const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const workspace = @import("../workspace_state.zig");
const reuse = @import("../reuse_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const operation = @import("types.zig").operation;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const Commands = @import("workspace_commands.zig").Operations(Types, Self);
        const Realization = @import("workspace_realization.zig").Operations(Types, Self);

        pub fn request(
            self: *Self,
            a: std.mem.Allocator,
            task: state.TaskId,
            authorized: workspace.Authorized,
        ) !state.Digest {
            return switch (authorized.command) {
                .program => |selected| program(self, a, task, authorized, selected),
                .work => |selected| work(self, a, task, selected),
                .context => |selected| switch (selected) {
                    .materialize, .select => operation(workspace.ContextRequest, a, .{
                        .task = task,
                        .command = selected,
                        .snapshot = authorized.snapshot,
                        .input = authorized.input,
                    }),
                    else => error.OperationConflict,
                },
                .placement => error.OperationConflict,
            };
        }

        fn program(
            self: *Self,
            a: std.mem.Allocator,
            task: state.TaskId,
            authorized: workspace.Authorized,
            selected: wc.Program,
        ) !state.Digest {
            return switch (selected) {
                .retain => |value| operation(reuse.RetainRequest, a, .{
                    .task = task,
                    .retain = value,
                }),
                .import => |value| operation(reuse.ImportRequest, a, .{
                    .task = task,
                    .import = value,
                }),
                .build => |value| build(self, a, task, authorized, value),
                .specialize => |value| operation(workspace.SpecializeRequest, a, .{
                    .task = task,
                    .program = try wp.identity(value.program, .program),
                    .hooks = value.hooks,
                }),
                .derive, .validate => operation(workspace.SemanticRequest, a, .{
                    .task = task,
                    .command = selected,
                }),
                else => error.OperationConflict,
            };
        }

        fn build(
            self: *Self,
            a: std.mem.Allocator,
            task: state.TaskId,
            authorized: workspace.Authorized,
            selected: @FieldType(wc.Program, "build"),
        ) !state.Digest {
            const text = try Commands.workspaceBuildText(self, a, task, selected);
            defer a.free(text);
            return operation(workspace.BuildRequest, a, .{
                .task = task,
                .source = .{ .bytes = text },
                .source_kind = selected.source_kind,
                .catalog = if (selected.source_kind == .component_recipe)
                    authorized.catalog
                else
                    null,
                .exposures = selected.exposures,
                .role = selected.role,
            });
        }

        fn work(
            self: *Self,
            a: std.mem.Allocator,
            task: state.TaskId,
            selected: wc.Work,
        ) !state.Digest {
            return switch (selected) {
                .start => |value| start(self, a, task, value),
                .observe => |value| operation(workspace.ObserveRequest, a, .{
                    .task = task,
                    .selection = value,
                }),
                .stop_observing => |value| operation(workspace.StopObservingRequest, a, .{
                    .task = task,
                    .expected = value,
                }),
                .pump => |value| operation(workspace.PumpRequest, a, .{
                    .task = task,
                    .command = value,
                }),
                .realize => |value| operation(
                    workspace.RealizeRequest,
                    a,
                    try Realization.workspaceRealizeRequest(self, a, task, value),
                ),
                .realize_controller => |value| operation(workspace.ControllerRealizeRequest, a, .{
                    .task = task,
                    .command = value,
                }),
                .request_cut => |value| operation(workspace.CutRequest, a, .{
                    .task = task,
                    .command = value,
                }),
                .guard => |value| operation(workspace.GuardRequest, a, .{
                    .task = task,
                    .command = .{ .guard = value },
                }),
                .unguard => |value| operation(workspace.GuardRequest, a, .{
                    .task = task,
                    .command = .{ .unguard = value },
                }),
                .interact => |value| operation(workspace.InteractionRequest, a, .{
                    .task = task,
                    .interaction = value,
                }),
                .advance, .park, .delegate, .cancel => control(a, task, selected),
                else => error.OperationConflict,
            };
        }

        fn start(
            self: *Self,
            a: std.mem.Allocator,
            task: state.TaskId,
            selected: @FieldType(wc.Work, "start"),
        ) !state.Digest {
            const prepared = try Commands.workspaceStartInput(self, a, task, selected);
            defer a.free(prepared.input);
            return operation(workspace.StartRequest, a, .{
                .task = task,
                .program = prepared.program,
                .input = .{ .bytes = prepared.input },
                .policy = selected.policy,
                .origin = prepared.origin,
                .runtime = prepared.runtime,
                .trial = selected.trial,
            });
        }

        fn control(a: std.mem.Allocator, task: state.TaskId, selected: wc.Work) !state.Digest {
            if (selected == .delegate and selected.delegate.interpretation != .none)
                return operation(workspace.DelegationRequest, a, .{
                    .task = task,
                    .command = selected.delegate,
                });
            const expected = switch (selected) {
                .advance, .park => |value| value,
                .delegate => |value| value.expected,
                .cancel => |value| value.expected,
                else => return error.OperationConflict,
            };
            const command: workspace.Command = switch (selected) {
                .advance => .advance,
                .park => .park,
                .delegate => |value| .{ .delegate = value.policy },
                .cancel => |value| .{ .cancel = .{ .bytes = value.reason.bytes } },
                else => return error.OperationConflict,
            };
            if (expected.work.kind == .residual) return operation(
                workspace.ResidualControlRequest,
                a,
                .{
                    .task = task,
                    .residual = try wp.identity(expected.work, .residual),
                    .execution = expected.execution_revision,
                    .control = expected.control_revision,
                    .command = command,
                },
            );
            return operation(workspace.ControlRequest, a, .{
                .task = task,
                .work = try wp.identity(expected.work, .work),
                .execution = expected.execution_revision,
                .control = expected.control_revision,
                .command = command,
            });
        }
    };
}
