const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const storage = @import("../store.zig");
const reuse = @import("../reuse_state.zig");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const json = @import("../json.zig");
const values = @import("../values.zig");
const task_types = @import("types.zig");
const preparation = @import("reuse_preparation.zig");
const wc = contracts.workspace;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Publication = @import("workspace_publication.zig").Operations(Types, Self);
        const Observations = @import("workspace_observations.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Preparation = preparation.Operations(Types, Self);

        pub fn retain(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            request: wc.Retain,
        ) !task_types.Admission {
            try Lifecycle.allowed(self);
            try authorizeCurrent(self, request.scope.bytes, .retain);
            const identity = try task_types.operation(reuse.RetainRequest, a, .{
                .task = task_id,
                .retain = request,
            });
            if (try Records.replay(self, a, operation_id, identity)) |prior| {
                if (self.workspace_replay == null) try discloseReceipt(self, a, prior.receipt);
                return prior;
            }
            var prepared = try Preparation.prepare(
                self,
                task_id,
                try wp.identity(request.program, .program),
                request.scope.bytes,
                request.description,
            );
            defer prepared.deinit();
            const store = Lifecycle.store(self);
            const encoded = try store.prepareDefinition(
                prepared.arena.allocator(),
                prepared.definition,
            );
            try recheck(self, a, prepared.parent);
            try self.profile.reuse.disclose(
                self.profile.authority,
                request.scope.bytes,
                prepared.disclosure,
            );
            try store.begin();
            defer store.rollback();
            try recheck(self, a, prepared.parent);
            try self.profile.reuse.authorize(self.profile.authority, request.scope.bytes, .retain);
            try retainPreparedAssets(store, prepared);
            const definition = try store.retainDefinition(encoded);
            return Publication.workspaceCommit(
                self,
                a,
                prepared.parent,
                operation_id,
                identity,
                definition.digest,
                .retained,
                definition,
                .{ .retain = .{
                    .request = request,
                    .definition = definition,
                } },
            );
        }

        pub fn importProgram(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            request: wc.Import,
        ) !task_types.Admission {
            try Lifecycle.allowed(self);
            try authorizeCurrent(self, request.locator.scope.bytes, .import);
            const identity = try task_types.operation(reuse.ImportRequest, a, .{
                .task = task_id,
                .import = request,
            });
            if (try Records.replay(self, a, operation_id, identity)) |prior| return prior;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try recheck(self, a, parent.value);
            const store = Lifecycle.store(self);
            if (store.transaction) return error.CompilerPreparationRequired;
            var definition = try readDefinition(self, a, request.locator);
            defer definition.deinit();
            try Preparation.validateDefinition(self, a, definition.value);
            try Programs.validateProgramCompiler(self, a, .{
                .id = try workspace.custodyId(a, task_id, definition.value.program.digest),
                .task = task_id,
                .artifact = definition.value.program,
                .description = definition.value.artifact,
            }, store);
            try store.begin();
            defer store.rollback();
            try recheck(self, a, parent.value);
            try authorizeCurrent(self, request.locator.scope.bytes, .import);
            const program = try Programs.storeProgramCustody(
                self,
                a,
                task_id,
                definition.value.artifact,
            );
            const bytes = try contracts.encodeOwned(reuse.Import, a, .{
                .task = task_id,
                .locator = request.locator,
                .definition = try store.objectReference(try locatorId(request.locator), null),
                .program = program,
                .artifact = definition.value.artifact,
            });
            defer a.free(bytes);
            const imported_observation = try store.putObject(bytes);
            return Publication.workspaceCommit(
                self,
                a,
                parent.value,
                operation_id,
                identity,
                imported_observation.digest,
                .imported,
                imported_observation,
                .{ .import = .{
                    .request = request,
                    .observation = imported_observation,
                } },
            );
        }

        fn recheck(self: *Self, a: std.mem.Allocator, frozen: state.Task) !void {
            try Lifecycle.allowed(self);
            try Lifecycle.requireCustody(self, a, frozen.id, null);
            var current = try self.task(a, frozen.id);
            defer current.deinit();
            if (current.value.revision != frozen.revision) return error.StaleOccurrence;
            if (Access.workspaceParentStopped(self, current.value)) return error.InvalidState;
        }

        fn authorizeCurrent(
            self: *Self,
            scope: []const u8,
            action: @import("../reuse_policy.zig").Action,
        ) !void {
            if (self.workspace_replay == null)
                try self.profile.reuse.authorize(self.profile.authority, scope, action);
        }

        pub fn readDefinition(
            self: *Self,
            a: std.mem.Allocator,
            locator: wc.RetainedLocator,
        ) !contracts.Decoded(reuse.Definition) {
            const bytes = (try Lifecycle.store(self).definitionBytes(
                a,
                locator.scope.bytes,
                try locatorId(locator),
            )) orelse return error.ArtifactUnavailable;
            defer a.free(bytes);
            var decoded = try contracts.decodeOwned(reuse.Definition, a, bytes);
            errdefer decoded.deinit();
            if (!std.mem.eql(u8, decoded.value.scope.bytes, locator.scope.bytes))
                return error.CorruptState;
            try Lifecycle.store(self).checkDependencies(
                reuse.Definition,
                state.Reference,
                .{ .digest = try locatorId(locator), .bytes = bytes.len },
                decoded.value,
            );
            return decoded;
        }

        fn discloseReceipt(self: *Self, a: std.mem.Allocator, receipt: state.Receipt) !void {
            if (receipt.workspace_kind != .retained) return error.OperationConflict;
            const store = Lifecycle.store(self);
            const bytes = try store.object(a, receipt.workspace_observation.?, null);
            defer a.free(bytes);
            var decoded = try contracts.decodeOwned(reuse.Definition, a, bytes);
            defer decoded.deinit();
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const scratch = arena.allocator();
            const build = try store.object(scratch, decoded.value.origin.build, null);
            const frozen = try preparation.freezeDisclosure(scratch, store, decoded.value, build);
            try self.profile.reuse.disclose(
                self.profile.authority,
                decoded.value.scope.bytes,
                frozen,
            );
        }

        pub fn observation(
            self: *Self,
            a: std.mem.Allocator,
            receipt: state.Receipt,
            bytes: []const u8,
        ) !json.Value {
            if (receipt.workspace_kind == .retained) {
                var decoded = try contracts.decodeOwned(reuse.Definition, a, bytes);
                defer decoded.deinit();
                try authorizeCurrent(self, decoded.value.scope.bytes, .retain);
                var result = json.object();
                try json.put(a, &result, "retained", try locatorJson(
                    a,
                    decoded.value.scope.bytes,
                    receipt.workspace.?,
                ));
                return result;
            }
            var decoded = try contracts.decodeOwned(reuse.Import, a, bytes);
            defer decoded.deinit();
            try authorizeCurrent(self, decoded.value.locator.scope.bytes, .import);
            var result = try Observations.workspaceProgramObservation(
                self,
                a,
                decoded.value.program.digest,
                decoded.value.artifact,
            );
            try json.put(a, &result, "retained", try values.toJson(
                wc.RetainedLocator,
                a,
                decoded.value.locator,
            ));
            return result;
        }
    };
}

fn retainPreparedAssets(store: *storage.Store, prepared: preparation.Prepared) !void {
    const origin = prepared.definition.origin;
    for (prepared.disclosure.history) |object| {
        if (std.meta.eql(object.reference, origin.build)) {
            _ = try store.putObject(object.bytes);
            continue;
        }
        for (origin.schemas.items) |schema| {
            if (std.meta.eql(object.reference, schema.definition)) {
                _ = try store.putObject(object.bytes);
                break;
            }
        }
    }
}

pub fn locatorId(locator: wc.RetainedLocator) !state.Digest {
    if (locator.id.bytes.len != 64) return error.InvalidReference;
    var id: state.Digest = undefined;
    _ = std.fmt.hexToBytes(&id, locator.id.bytes) catch return error.InvalidReference;
    if (!std.mem.eql(u8, locator.id.bytes, &std.fmt.bytesToHex(id, .lower)))
        return error.InvalidReference;
    return id;
}

pub fn locatorJson(a: std.mem.Allocator, scope: []const u8, id: state.Digest) !json.Value {
    return values.toJson(wc.RetainedLocator, a, .{
        .scope = .{ .bytes = scope },
        .id = .{ .bytes = &std.fmt.bytesToHex(id, .lower) },
    });
}
