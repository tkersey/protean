const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const storage = @import("../store.zig");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const values = @import("../values.zig");
const proposal = @import("../projection_proposal.zig");
const construction = @import("../program_construction.zig");
const WorkspaceValueReference = @import("types.zig").WorkspaceValueReference;
const wc = contracts.workspace;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Contexts = @import("workspace_contexts.zig").Operations(Types, Self);
        const Consumers = @import("workspace_consumers.zig").Operations(Types, Self);
        const Execution = @import("workspace_execution.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        const store = Lifecycle.store;
        const record = Records.record;

        pub const Admitted = struct {
            arena: std.heap.ArenaAllocator,
            view: workspace.ViewArtifact,
            consumer: ?union(enum) {
                controller: workspace.ConsumerInterface,
                model: state.Digest,
            } = null,

            pub fn deinit(self: *Admitted) void {
                self.arena.deinit();
                self.* = undefined;
            }

            pub fn requireController(
                self: Admitted,
                current: ?workspace.ConsumerInterface,
            ) !void {
                const observed = self.consumer orelse return;
                const actual = current orelse return error.InvalidConsumer;
                if (observed != .controller or
                    !std.meta.eql(
                        observed.controller.protected_identity,
                        actual.protected_identity,
                    ) or
                    !std.meta.eql(observed.controller.model_profile, actual.model_profile))
                    return error.StaleConsumer;
            }

            pub fn requireModel(
                self: Admitted,
                a: std.mem.Allocator,
                current: ?workspace.ModelBinding,
            ) !void {
                const observed = self.consumer orelse return;
                const actual = current orelse return error.InvalidConsumer;
                const after = try contracts.encodeOwned(workspace.ModelBinding, a, actual);
                defer a.free(after);
                if (observed != .model or !std.meta.eql(observed.model, storage.digest(after)))
                    return error.StaleConsumer;
            }
        };

        pub fn admit(
            self: *Self,
            allocator: std.mem.Allocator,
            parent: state.Task,
            result: wc.Ref,
            target: wc.ConsumerTarget,
            current: bool,
        ) !Admitted {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const a = arena.allocator();
            const value = try Contexts.workspaceValueReference(self, a, parent.id, result);
            var work = try self.workspaceWork(a, parent.id, try projectionWork(self, a, value));
            defer work.deinit();
            const prepared = try reconstruct(self, a, parent, value, work.value, target, current);
            return .{ .arena = arena, .view = prepared.view, .consumer = prepared.consumer };
        }

        pub fn restore(
            self: *Self,
            allocator: std.mem.Allocator,
            parent: state.Task,
            result: wc.Ref,
            target: wc.ConsumerTarget,
            retained: state.Reference,
        ) !Admitted {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const a = arena.allocator();
            var saved = try contracts.decodeOwned(
                workspace.ViewArtifact,
                a,
                try store(self).object(a, retained, null),
            );
            defer saved.deinit();
            const selected = saved.value.projection orelse return error.InvalidArchive;
            var work = try contracts.decodeOwned(
                workspace.Work,
                a,
                try store(self).object(a, selected.work, null),
            );
            defer work.deinit();
            const value = try Contexts.workspaceValueReference(self, a, parent.id, result);
            const prepared = try reconstruct(self, a, parent, value, work.value, target, false);
            const actual = try contracts.encodeOwned(workspace.ViewArtifact, a, prepared.view);
            if (!std.meta.eql(reference(actual), retained)) return error.InvalidArchive;
            return .{ .arena = arena, .view = prepared.view, .consumer = prepared.consumer };
        }

        fn projectionWork(
            self: *Self,
            a: std.mem.Allocator,
            value: WorkspaceValueReference,
        ) !state.Digest {
            var origin = try contracts.decodeOwned(
                workspace.Derivation,
                a,
                try store(self).object(a, value.provenance, null),
            );
            defer origin.deinit();
            if (origin.value.kind != .computation and origin.value.kind != .trial)
                return error.InvalidProjection;
            return origin.value.work orelse return error.InvalidProjection;
        }

        const Prepared = struct {
            view: workspace.ViewArtifact,
            consumer: @FieldType(Admitted, "consumer"),
        };

        fn reconstruct(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            value: WorkspaceValueReference,
            work: workspace.Work,
            target: wc.ConsumerTarget,
            current: bool,
        ) !Prepared {
            if (!std.meta.eql(work.task, parent.id) or
                !std.meta.eql(work.id, try projectionWork(self, a, value)))
                return error.InvalidProjection;
            var program = try self.workspaceProgram(a, parent.id, work.program);
            defer program.deinit();
            try validateResult(self, a, parent, work, program.value, value.artifact);
            var decoded = try proposal.decodeResult(
                a,
                try store(self).object(a, value.schema, null),
                try store(self).object(a, value.value, null),
            );
            defer decoded.deinit();
            try matchInput(self, a, work, program.value, decoded.header.consumer);
            var observed = try Consumers.open(self, a, parent.id, decoded.header.consumer);
            defer observed.deinit();
            const consumer = observed.value.evidence.read.consumer;
            try requireTarget(consumer.selection.target, target);
            if (current) try Consumers.applicable(self, a, parent, consumer);
            try validateTrial(work, consumer);
            try validateLineage(self, a, parent.id, value.artifact);
            const references = try admitBlocks(self, a, parent.id, decoded.header.blocks.items);
            const work_bytes = try contracts.encodeOwned(workspace.Work, a, work);
            const observation_bytes = try contracts.encodeOwned(
                workspace.ReplyObservation,
                a,
                observed.value,
            );
            return .{ .consumer = try consumerIdentity(a, consumer), .view = .{
                .values = .{ .items = &.{} },
                .projection = .{
                    .result = value.artifact,
                    .work = reference(work_bytes),
                    .program = program.value.artifact,
                    .input = work.input_value orelse return error.InvalidProjection,
                    .observation = reference(observation_bytes),
                    .values = .{ .items = references },
                },
            } };
        }

        fn requireTarget(observed: wc.ConsumerTarget, expected: wc.ConsumerTarget) !void {
            switch (observed) {
                .controller => if (expected != .controller) return error.ConsumerMismatch,
                .model => |actual| {
                    if (expected != .model) return error.ConsumerMismatch;
                    const target = expected.model;
                    if (!std.meta.eql(
                        try wp.identity(actual.expected.work, .work),
                        try wp.identity(target.expected.work, .work),
                    ) or !std.meta.eql(
                        try wp.identity(actual.port, .port),
                        try wp.identity(target.port, .port),
                    ) or actual.expected.execution_revision != target.expected.execution_revision or
                        actual.expected.control_revision != target.expected.control_revision or
                        actual.generation != target.generation or
                        !std.mem.eql(u8, actual.profile_id.bytes, target.profile_id.bytes) or
                        !std.mem.eql(u8, actual.effort.bytes, target.effort.bytes))
                        return error.ConsumerMismatch;
                },
            }
        }

        fn consumerIdentity(
            a: std.mem.Allocator,
            observed: workspace.ConsumerObservation,
        ) !@FieldType(Admitted, "consumer") {
            if (observed.selection.target == .controller)
                return .{ .controller = observed.interface };
            const model = observed.model orelse return error.InvalidConsumer;
            const bytes = try contracts.encodeOwned(workspace.ModelBinding, a, model);
            defer a.free(bytes);
            return .{ .model = storage.digest(bytes) };
        }

        pub fn select(
            self: *Self,
            allocator: std.mem.Allocator,
            parent: state.Task,
            selection: wc.Selection,
            target: wc.ConsumerTarget,
            current: bool,
        ) !Admitted {
            if (selection == .projected)
                return admit(self, allocator, parent, selection.projected, target, current);
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const a = arena.allocator();
            const references = try a.alloc(state.Reference, selection.values.items.len);
            for (selection.values.items, references) |ref, *out|
                out.* = (try Contexts.workspaceValueReference(self, a, parent.id, ref)).artifact;
            return .{ .arena = arena, .view = .{ .values = .{ .items = references } } };
        }

        pub fn delegatedTarget(selection: @FieldType(wc.Work, "delegate")) wc.ConsumerTarget {
            const model = selection.interpretation.model;
            return .{ .model = .{
                .expected = selection.expected,
                .port = model.port,
                .generation = model.generation,
                .profile_id = model.profile_id,
                .effort = model.effort,
            } };
        }

        fn reference(bytes: []const u8) state.Reference {
            return .{ .digest = storage.digest(bytes), .bytes = bytes.len };
        }

        fn validateResult(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            work: workspace.Work,
            program: workspace.Program,
            result: state.Reference,
        ) !void {
            if (work.outcome_kind != .completed or work.result_value == null or
                !std.meta.eql(work.result_value.?, result) or work.delegation != null or
                program.description.controller != null) return error.InvalidProjection;
            try construction.requirePure(
                a,
                program.description.source_kind,
                try store(self).object(a, program.description.source, null),
                try store(self).object(a, program.description.image, null),
            );
            var checked: Snapshots.SnapshotValidation = .{
                .allocator = a,
                .observer_successors = .init(a, parent.id),
            };
            defer checked.deinit();
            try Snapshots.validateWorkspacePublication(self, a, parent.id, .{
                .work = work,
                .occurrence = null,
            });
            try Snapshots.validateSnapshotExecution(
                self,
                a,
                parent,
                work,
                program,
                false,
                &checked,
            );
        }

        fn matchInput(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            program: workspace.Program,
            consumer: wc.Ref,
        ) !void {
            var input = try proposal.decodeInput(
                a,
                try store(self).object(a, program.description.input_schema, null),
                try store(self).object(a, work.input, null),
            );
            defer input.deinit();
            if (!std.meta.eql(
                try wp.identity(input.header, .observation),
                try wp.identity(consumer, .observation),
            )) return error.ConsumerMismatch;
        }

        fn validateTrial(work: workspace.Work, observed: workspace.ConsumerObservation) !void {
            const target_trial = if (observed.target) |target| target.work.trial else null;
            if (!std.meta.eql(work.trial, target_trial)) return error.InvalidProjection;
        }

        fn admitBlocks(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            blocks: []const wc.PresentationBlock,
        ) ![]const state.Reference {
            var references: std.ArrayList(state.Reference) = .empty;
            for (blocks) |block| {
                const selected = switch (block) {
                    .value => |ref| ref,
                    .source => |slice| slice.value,
                    .computed, .explanation => continue,
                };
                const value = try Contexts.workspaceValueReference(self, a, task_id, selected);
                try validateLineage(self, a, task_id, value.artifact);
                if (block == .source) try validateSource(self, a, value, block.source);
                try references.append(a, value.artifact);
            }
            return references.toOwnedSlice(a);
        }

        fn validateSource(self: *Self, a: std.mem.Allocator, value: anytype, slice: anytype) !void {
            var origin = try contracts.decodeOwned(
                workspace.Derivation,
                a,
                try store(self).object(a, value.provenance, null),
            );
            defer origin.deinit();
            if (origin.value.kind != .acquisition) return error.InvalidSourceSlice;
            const schema = try values.schemaBytes(contracts.Utf8, a);
            if (!std.meta.eql(value.schema, reference(schema))) return error.InvalidSourceSlice;
            var text = try contracts.decodeOwned(
                contracts.Utf8,
                a,
                try store(self).object(a, value.value, null),
            );
            defer text.deinit();
            const bytes = text.value.bytes;
            if (slice.offset > bytes.len or slice.length > bytes.len - slice.offset)
                return error.InvalidSourceSlice;
            const selected = bytes[@intCast(slice.offset)..][0..@intCast(slice.length)];
            if (!std.unicode.utf8ValidateSlice(selected)) return error.InvalidSourceSlice;
        }

        pub fn validateLineage(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            root: state.Reference,
        ) !void {
            var seen: std.AutoHashMap(state.Digest, void) = .init(a);
            defer seen.deinit();
            var pending: std.ArrayList(state.Reference) = .empty;
            defer pending.deinit(a);
            try pending.append(a, root);
            while (pending.pop()) |ref| {
                const entry = try seen.getOrPut(ref.digest);
                if (entry.found_existing) continue;
                const value = try Contexts.workspaceValueReference(
                    self,
                    a,
                    task_id,
                    try wp.reference(a, .value, ref.digest),
                );
                if (!std.meta.eql(value.artifact, ref)) return error.InvalidProjection;
                var origin = try contracts.decodeOwned(
                    workspace.Derivation,
                    a,
                    try store(self).object(a, value.provenance, null),
                );
                defer origin.deinit();
                try pending.appendSlice(a, origin.value.sources.items);
            }
        }
    };
}
