const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const kosmos = @import("kosmos");
const values = @import("../values.zig");
const workspace = @import("../workspace_state.zig");
const instrument = @import("../workspace_instrument.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const InspectionValue = task_types.InspectionValue;
const Work = task_types.Work;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const record = Records.record;
        const store = Lifecycle.store;
        const validateWorkspacePublication = Snapshots.validateWorkspacePublication;
        const workspaceContentCustody = Programs.workspaceContentCustody;
        const workspaceRuntime = Programs.workspaceRuntime;
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        pub fn inspectionSelection(work: workspace.Work, selected: wc.GuestViewSelection) !void {
            if (!std.meta.eql(work.id, try wp.identity(selected.expected.work, .work)) or
                work.execution_revision != selected.expected.execution_revision or
                work.control_revision != selected.expected.control_revision or
                work.realization_revision != selected.realization_revision)
                return error.StaleRevision;
        }
        pub fn inspectionRuntime(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
        ) !kosmos.Prepared {
            var program = try self.workspaceProgram(a, work.task, work.program);
            defer program.deinit();
            const image =
                try store(self).object(a, program.value.description.image, null);
            defer a.free(image);
            if (work.runtime) |ref| {
                var selected =
                    try workspaceRuntime(self, a, work.task, ref.digest, work.program);
                defer selected.deinit();
                return kosmos.Prepared.initWithRuntime(a, image, &selected.admitted);
            }
            return self.program.prepare(a, image);
        }
        pub fn workspaceInspectionBytes(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            origin: workspace.Inspection,
        ) !InspectionValue {
            const work = origin.observation.work;
            if (!std.meta.eql(work.task, task_id)) return error.Denied;
            try validateWorkspacePublication(self, a, task_id, origin.observation);
            var prepared = try inspectionRuntime(self, a, work);
            defer prepared.deinit();
            const code = try store(self).object(a, origin.runtime_code, null);
            defer a.free(code);
            if (!std.meta.eql(prepared.runtime.identity, origin.runtime_code.digest))
                return error.InvalidRuntime;
            if (origin.level == .outer_execution)
                return workspaceOuterInspection(self, a, &prepared, origin);
            const checkpoint = try store(self).object(a, work.checkpoint, null);
            defer a.free(checkpoint);
            const mask = try inspectionNodeMask(a, checkpoint, origin.nodes);
            defer if (mask) |items| a.free(items);
            const disclosure = try operation(struct {
                task: state.TaskId,
                work: state.Digest,
                checkpoint: state.Reference,
                scope: wc.NodeScope,
                disclosure: ?wc.Disclosure,
            }, a, .{
                .task = task_id,
                .work = work.id,
                .checkpoint = work.checkpoint,
                .scope = origin.nodes,
                .disclosure = origin.disclosure,
            });
            if (origin.disclosure) |selected| return workspaceDetailedInspection(
                self,
                a,
                &prepared,
                work,
                checkpoint,
                mask,
                selected,
                disclosure,
            );
            var view = try kosmos.RuntimeViews.capture(
                a,
                prepared.guest.core.?.admitted(),
                checkpoint,
                .{
                    .guest = prepared.guest.core.?.admitted().identity(),
                    .core = prepared.runtime.content.value.manifest.source,
                    .realization = prepared.runtime.identity,
                    .checkpoint = work.checkpoint.digest,
                    .execution = work.id,
                    .guest_revision = work.execution_revision,
                    .realization_revision = work.realization_revision,
                    .disclosure = disclosure,
                },
                mask,
            );
            defer view.deinit();
            const schema = try kosmos.RuntimeViews.schemaBytes(a);
            errdefer a.free(schema);
            return .{ .schema = schema, .value = try kosmos.RuntimeViews.encode(a, view.value) };
        }
        fn inspectionNodeMask(
            a: std.mem.Allocator,
            checkpoint: []const u8,
            nodes: wc.NodeScope,
        ) !?[]bool {
            var mask: ?[]bool = null;
            errdefer if (mask) |items| a.free(items);
            if (nodes == .selected) {
                var decoded = try data.state_image.decodeGraphBorrowed(a, checkpoint, .{});
                defer decoded.deinit();
                mask = try a.alloc(bool, decoded.state.nodes.len);
                @memset(mask.?, false);
                for (nodes.selected.items) |node| {
                    if (node >= mask.?.len) return error.InvalidDisclosure;
                    mask.?[@intCast(node)] = true;
                }
            }
            return mask;
        }
        fn workspaceOuterInspection(
            self: *Self,
            a: std.mem.Allocator,
            prepared: *kosmos.Prepared,
            origin: workspace.Inspection,
        ) !InspectionValue {
            if (origin.disclosure) |selected| if (selected.snapshot)
                return error.InvalidDisclosure;
            const work = origin.observation.work;
            const ref =
                if (work.outer_operation) |pending|
                    pending.capsule
                else
                    work.runtime_capsule orelse
                        return error.OuterCutUnavailable;
            const bytes = try store(self).object(a, ref, null);
            defer a.free(bytes);
            var capsule = try kosmos.RuntimeCapsule.read(a, bytes);
            defer capsule.deinit();
            if (capsule.value.record.kind != .outer_execution)
                return error.OuterCutUnavailable;
            var graph = try data.state_image.decodeGraphBorrowed(a, capsule.value.checkpoint, .{});
            defer graph.deinit();
            var mask: ?[]bool = null;
            defer if (mask) |selected| a.free(selected);
            if (origin.nodes == .selected) {
                mask = try a.alloc(bool, graph.state.nodes.len);
                @memset(mask.?, false);
                for (origin.nodes.selected.items) |node| {
                    if (node >= mask.?.len) return error.InvalidDisclosure;
                    mask.?[@intCast(node)] = true;
                }
            }
            const disclosure = try @import("../workspace_observers.zig").disclosure(
                a,
                graph.state.nodes.len,
                mask,
                origin.disclosure orelse .{},
            );
            defer disclosure.deinit(a);
            const identity = try operation(workspace.Inspection, a, origin);
            var view = try kosmos.RuntimeCapsule.inspectOuter(
                a,
                prepared.guest.core.?.admitted(),
                &prepared.runtime,
                bytes,
                disclosure.value,
                identity,
            );
            defer view.deinit();
            const schema = try kosmos.RuntimeCapsule.outerViewSchemaBytes(a);
            errdefer a.free(schema);
            return .{
                .schema = schema,
                .value = try kosmos.RuntimeCapsule.encodeOuterView(a, view.value),
            };
        }
        fn workspaceDetailedInspection(
            _: *Self,
            a: std.mem.Allocator,
            prepared: *kosmos.Prepared,
            work: workspace.Work,
            checkpoint: []const u8,
            nodes: ?[]const bool,
            selected: wc.Disclosure,
            disclosure: state.Digest,
        ) !InspectionValue {
            var graph = try data.state_image.decodeGraphBorrowed(a, checkpoint, .{});
            defer graph.deinit();
            const scope = try @import("../workspace_observers.zig").disclosure(
                a,
                graph.state.nodes.len,
                nodes,
                selected,
            );
            defer scope.deinit(a);
            var view = try kosmos.RuntimeViews.captureDetailed(
                a,
                prepared.guest.core.?.admitted(),
                checkpoint,
                .{
                    .guest = prepared.guest.core.?.admitted().identity(),
                    .core = prepared.runtime.content.value.manifest.source,
                    .realization = prepared.runtime.identity,
                    .checkpoint = work.checkpoint.digest,
                    .execution = work.id,
                    .guest_revision = work.execution_revision,
                    .realization_revision = work.realization_revision,
                    .disclosure = disclosure,
                },
                scope.value,
            );
            defer view.deinit();
            const schema = try kosmos.RuntimeViews.detailedSchemaBytes(a);
            errdefer a.free(schema);
            return .{
                .schema = schema,
                .value = try kosmos.RuntimeViews.encodeDetailed(a, view.value),
            };
        }
        pub fn validateDelegatedValue(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            value: workspace.Value,
        ) !void {
            const origin = value.derivation;
            if (origin.kind != .judgment or origin.program != null or origin.acquisition != null or
                origin.frozen_input != null or origin.delegation == null or origin.capture == null)
                return error.InvalidArchive;
            var work =
                try self.workspaceWork(a, task_id, origin.work orelse return error.InvalidArchive);
            defer work.deinit();
            if (work.value.outcome_kind != .completed or
                !std.meta.eql(work.value.delegation, origin.delegation) or !std.meta.eql(
                work.value.answer_value,
                value.artifact,
            )) return error.InvalidArchive;
            var delegation = try contracts.decodeOwned(
                workspace.Delegation,
                a,
                try store(self).object(a, origin.delegation.?, null),
            );
            defer delegation.deinit();
            if (delegation.value.selection != .model or !std.meta.eql(
                delegation.value.instrument,
                work.value.id,
            ) or !std.meta.eql(delegation.value.task, task_id) or
                origin.sources.items.len != delegation.value.inputs.items.len)
                return error.InvalidArchive;
            for (origin.sources.items, delegation.value.inputs.items) |left, right|
                if (!std.meta.eql(left, right)) return error.InvalidArchive;
            try validateDelegatedAnswer(self, a, work.value, delegation.value, value);
            try validateDelegatedCapture(self, a, task_id, work.value, origin);
        }
        fn validateDelegatedAnswer(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            delegation: workspace.Delegation,
            value: workspace.Value,
        ) !void {
            var port = try contracts.decodeOwned(
                workspace.Port,
                a,
                try store(self).object(a, delegation.port, null),
            );
            defer port.deinit();
            var result = try contracts.decodeOwned(
                instrument.Output,
                a,
                try store(self).object(a, work.result orelse return error.InvalidArchive, null),
            );
            defer result.deinit();
            if (result.value != .answer or !std.meta.eql(
                value.description.schema,
                port.value.interface.argument,
            ) or !std.meta.eql(value.description.value, state.Reference{
                .digest = storage.digest(result.value.answer.bytes),
                .bytes = result.value.answer.bytes.len,
            })) return error.InvalidArchive;
        }
        fn validateDelegatedCapture(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            work: workspace.Work,
            origin: workspace.Derivation,
        ) !void {
            var pending = try record(
                self,
                occurrence.Occurrence,
                a,
                "occurrence",
                work.instrument_occurrence orelse return error.InvalidArchive,
                task_id,
            );
            defer pending.deinit();
            if (pending.value.state != .admitted or pending.value.state.admitted != .reply)
                return error.InvalidArchive;
            var capture_value = try record(
                self,
                state.Capture,
                a,
                "capture",
                pending.value.state.admitted.reply.attempt,
                task_id,
            );
            defer capture_value.deinit();
            if (!std.meta.eql(capture_value.value.response, origin.capture))
                return error.InvalidArchive;
        }
        pub fn workspaceSnapshotAccess(parent: state.Task, snapshot: state.Reference) !void {
            for (parent.resources.items) |ref| if (std.meta.eql(ref, snapshot)) return;
            return error.Denied;
        }
        pub fn workspaceSnapshotBytes(
            self: *Self,
            a: std.mem.Allocator,
            origin: workspace.SnapshotRange,
        ) !struct {
            schema: []u8,
            value: []u8,
        } {
            const bytes = try store(self).object(a, origin.snapshot, null);
            defer a.free(bytes);
            var source = try @import("../repository.zig").Snapshot.openBorrowed(a, bytes);
            defer source.deinit();
            const file = source.get(origin.path.bytes) orelse return error.CorruptState;
            if (!std.meta.eql(file.sha256, origin.file_digest) or
                origin.start > origin.end or
                origin.end > file.contents.bytes.len or
                origin.file_bytes != file.contents.bytes.len or
                origin.excluded_entries != source.decoded.value.excluded_entries)
                return error.CorruptState;
            const part = file.contents.bytes[@intCast(origin.start)..@intCast(origin.end)];
            if (std.unicode.utf8ValidateSlice(part)) return .{
                .schema = try values.schemaBytes(contracts.Utf8, a),
                .value = try contracts.encodeOwned(contracts.Utf8, a, .{ .bytes = part }),
            };
            return .{
                .schema = try values.schemaBytes(contracts.Bytes(null), a),
                .value = try contracts.encodeOwned(contracts.Bytes(null), a, .{ .bytes = part }),
            };
        }
        pub fn workspaceSnapshotRange(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            snapshot: state.Reference,
            selection: anytype,
        ) !workspace.SnapshotRange {
            try workspaceSnapshotAccess(parent, snapshot);
            const bytes = try store(self).object(a, snapshot, null);
            defer a.free(bytes);
            var source = try @import("../repository.zig").Snapshot.openBorrowed(a, bytes);
            defer source.deinit();
            const file = source.get(selection.path.bytes) orelse return error.SourceMissing;
            if (selection.offset > file.contents.bytes.len) return error.InvalidRange;
            return .{
                .snapshot = snapshot,
                .path = selection.path,
                .file_digest = file.sha256,
                .start = selection.offset,
                .end = selection.offset + @min(
                    selection.maximum,
                    file.contents.bytes.len - selection.offset,
                ),
                .file_bytes = file.contents.bytes.len,
                .excluded_entries = source.decoded.value.excluded_entries,
            };
        }
        pub fn workspaceMaterializeSnapshot(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            snapshot: state.Reference,
            selection: anytype,
        ) !state.Reference {
            const origin = try workspaceSnapshotRange(self, a, parent, snapshot, selection);
            const derived = try workspaceSnapshotBytes(self, a, origin);
            defer a.free(derived.schema);
            defer a.free(derived.value);
            return workspacePublishValue(self, a, parent.id, try store(
                self,
            ).putObject(derived.schema), try store(self).putObject(derived.value), .{
                .kind = .acquisition,
                .sources = .{ .items = &.{} },
                .acquisition = origin,
            });
        }
        pub fn workspacePublishValue(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            schema: state.Reference,
            value: state.Reference,
            derivation: workspace.Derivation,
        ) !state.Reference {
            const provenance_bytes = try contracts.encodeOwned(workspace.Derivation, a, derivation);
            defer a.free(provenance_bytes);
            const artifact: workspace.ValueArtifact = .{
                .schema = schema,
                .value = value,
                .provenance = try store(self).putObject(provenance_bytes),
            };
            const bytes = try contracts.encodeOwned(workspace.ValueArtifact, a, artifact);
            defer a.free(bytes);
            const ref = try store(self).putObject(bytes);
            const key = try workspaceContentCustody(a, task_id, ref.digest);
            const record_value: workspace.Value = .{
                .id = key,
                .task = task_id,
                .artifact = ref,
                .description = artifact,
                .derivation = derivation,
            };
            if (try store(self).recordBytes(a, "workspace_value", key, task_id)) |prior| {
                defer a.free(prior);
                const expected = try contracts.encodeOwned(workspace.Value, a, record_value);
                defer a.free(expected);
                if (!same(prior, expected)) return error.CorruptState;
            } else try store(self).createRecord(
                workspace.Value,
                "workspace_value",
                key,
                task_id,
                record_value,
            );
            return ref;
        }
    };
}
