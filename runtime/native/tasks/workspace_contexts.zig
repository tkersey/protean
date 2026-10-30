const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const storage = @import("../store.zig");
const kosmos = @import("kosmos");
const json = @import("../json.zig");
const values = @import("../values.zig");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const construction = @import("../program_construction.zig");
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const PreparedSemanticValue = task_types.PreparedSemanticValue;
const WorkspaceValueReference = task_types.WorkspaceValueReference;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const freezeWorkspaceWork = Access.freezeWorkspaceWork;
        const inspectionRuntime = inspection_ops.inspectionRuntime;
        const inspectionSelection = inspection_ops.inspectionSelection;
        const record = Records.record;
        const renderSemanticValue = Compiler.renderSemanticValue;
        const replay = Records.replay;
        const requireCustody = Lifecycle.requireCustody;
        const semanticRuntime = Observations.semanticRuntime;
        const store = Lifecycle.store;
        const validateDelegatedValue = inspection_ops.validateDelegatedValue;
        const workspaceCommit = Publication.workspaceCommit;
        const workspaceContentCustody = Programs.workspaceContentCustody;
        const workspaceInspectionBytes = inspection_ops.workspaceInspectionBytes;
        const workspaceMaterializeSnapshot = inspection_ops.workspaceMaterializeSnapshot;
        const workspaceOwnedDescriptor = Sources.workspaceOwnedDescriptor;
        const workspaceParentStopped = Access.workspaceParentStopped;
        const workspacePublishValue = inspection_ops.workspacePublishValue;
        const workspaceReadBasis = Replay.workspaceReadBasis;
        const workspaceSnapshotAccess = inspection_ops.workspaceSnapshotAccess;
        const workspaceSnapshotBytes = inspection_ops.workspaceSnapshotBytes;
        const Compiler = @import("compiler_preparation.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const inspection_ops = @import("workspace_inspection.zig").Operations(Types, Self);
        const Observations = @import("workspace_observations.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Publication = @import("workspace_publication.zig").Operations(Types, Self);
        const Replay = @import("workspace_replay.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        const Sources = @import("workspace_sources.zig").Operations(Types, Self);
        pub fn workspaceContextMutation(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            command: wc.Context,
            snapshot: ?state.Reference,
            input: ?state.Reference,
        ) !Admission {
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            const Request = workspace.ContextRequest;
            const request = try operation(Request, a, .{
                .task = task_id,
                .command = command,
                .snapshot = snapshot,
                .input = input,
            });
            if (try replay(self, a, operation_id, request)) |prior| return prior;
            try requireCustody(self, a, task_id, null);
            if (workspaceParentStopped(self, parent.value)) return error.InvalidState;
            var compiler_facts: Compiler.CompilerFacts = .{ .allocator = self.allocator };
            defer compiler_facts.deinit();
            const prior_compiler_facts = self.compiler_facts;
            if (self.compiler_facts == null) self.compiler_facts = &compiler_facts;
            defer self.compiler_facts = prior_compiler_facts;
            try prepareWorkspaceContext(self, a, task_id, command);
            var semantic = try prepareContextSemanticValue(self, a, parent.value, command);
            defer if (semantic) |*prepared| prepared.deinit(a);
            try store(self).begin();
            defer store(self).rollback();
            const artifact: state.Reference, const kind: @FieldType(wc.Ref, "kind") =
                switch (command) {
                    .materialize => |materialize| .{
                        try materializeWorkspaceContext(
                            self,
                            a,
                            task_id,
                            parent.value,
                            materialize,
                            snapshot,
                            input,
                            semantic,
                        ),
                        .value,
                    },
                    .select => |selection| .{
                        try selectWorkspaceContext(self, a, task_id, selection),
                        .view,
                    },
                    else => return error.InvalidState,
                };
            return workspaceCommit(
                self,
                a,
                parent.value,
                operation_id,
                request,
                artifact.digest,
                kind,
                artifact,
                .{ .context = .{ .command = command, .snapshot = snapshot, .input = input } },
            );
        }
        fn prepareContextSemanticValue(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            command: wc.Context,
        ) !?PreparedSemanticValue {
            return if (command == .materialize and command.materialize.input == .semantic_source)
                try prepareSemanticValue(self, a, parent, command.materialize.input.semantic_source)
            else
                null;
        }
        fn materializeWorkspaceContext(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            parent: state.Task,
            materialize: @FieldType(wc.Context, "materialize"),
            snapshot: ?state.Reference,
            input: ?state.Reference,
            semantic: ?PreparedSemanticValue,
        ) !state.Reference {
            if (semantic) |prepared| return materializeSemanticContext(
                self,
                a,
                task_id,
                materialize,
                prepared,
            );
            if (materialize.input == .guest_view)
                return materializeGuestContext(self, a, task_id, materialize);
            if (materialize.input == .authorized_input)
                return materializeAuthorizedContext(self, a, task_id, materialize, parent, input);
            if (materialize.input == .snapshot) {
                const selection = materialize.input.snapshot;
                if (materialize.sources.items.len != 0) return error.InvalidMaterialization;
                const source = snapshot orelse return error.Denied;
                const result = try workspaceMaterializeSnapshot(self, a, parent, source, selection);
                return result;
            }
            return materializeDerivedContext(self, a, task_id, materialize);
        }
        fn selectWorkspaceContext(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            selection: @FieldType(wc.Context, "select"),
        ) !state.Reference {
            const references = try a.alloc(state.Reference, selection.values.items.len);
            defer a.free(references);
            for (selection.values.items, references) |ref, *out|
                out.* =
                    (try workspaceValueReference(self, a, task_id, ref)).artifact;
            const view: workspace.ViewArtifact = .{ .values = .{ .items = references } };
            const bytes = try contracts.encodeOwned(workspace.ViewArtifact, a, view);
            defer a.free(bytes);
            const ref = try store(self).putObject(bytes);
            const key = try workspaceContentCustody(a, task_id, ref.digest);
            if (try store(self).recordBytes(a, "workspace_view", key, task_id)) |prior| {
                defer a.free(prior);
                const expected = try contracts.encodeOwned(workspace.View, a, .{
                    .id = key,
                    .task = task_id,
                    .artifact = ref,
                    .description = view,
                });
                defer a.free(expected);
                if (!same(prior, expected)) return error.CorruptState;
            } else try store(self).createRecord(
                workspace.View,
                "workspace_view",
                key,
                task_id,
                .{ .id = key, .task = task_id, .artifact = ref, .description = view },
            );
            return ref;
        }
        fn materializeSemanticContext(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            materialize: @FieldType(wc.Context, "materialize"),
            prepared: PreparedSemanticValue,
        ) !state.Reference {
            if (materialize.sources.items.len != 0) return error.InvalidMaterialization;
            _ = try store(self).putObject(prepared.runtime);
            const result = try workspacePublishValue(
                self,
                a,
                task_id,
                try store(self).putObject(prepared.schema),
                try store(self).putObject(prepared.value),
                .{
                    .kind = .inspection,
                    .sources = .{ .items = &.{} },
                    .semantic_source = prepared.origin,
                },
            );
            return result;
        }
        fn materializeGuestContext(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            materialize: @FieldType(wc.Context, "materialize"),
        ) !state.Reference {
            if (materialize.sources.items.len != 0) return error.InvalidMaterialization;
            const selection = materialize.input.guest_view;
            const observed =
                try freezeWorkspaceWork(self, a, task_id, selection.expected.work, false);
            try inspectionSelection(observed.work, selection);
            // The controller can disclose graph metadata of its own
            // work. Node selection narrows that grant; it never
            // exposes payload, source text or another task's work.
            var prepared = try inspectionRuntime(self, a, observed.work);
            defer prepared.deinit();
            const code = try prepared.runtime.encode(a);
            defer a.free(code);
            const origin: workspace.Inspection = .{
                .level = selection.level,
                .observation = observed,
                .nodes = selection.nodes,
                .disclosure = selection.disclosure,
                .runtime_code = try store(self).putObject(code),
            };
            const derived = try workspaceInspectionBytes(self, a, task_id, origin);
            defer a.free(derived.schema);
            defer a.free(derived.value);
            return try workspacePublishValue(
                self,
                a,
                task_id,
                try store(self).putObject(derived.schema),
                try store(self).putObject(derived.value),
                .{
                    .kind = .inspection,
                    .sources = .{ .items = &.{} },
                    .inspection = origin,
                },
            );
        }
        fn materializeAuthorizedContext(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            materialize: @FieldType(wc.Context, "materialize"),
            parent: state.Task,
            input: ?state.Reference,
        ) !state.Reference {
            if (materialize.sources.items.len != 0) return error.InvalidMaterialization;
            const ref = input orelse return error.UnauthorizedInput;
            try workspaceSnapshotAccess(parent, ref);
            const bytes = try store(self).object(a, ref, null);
            defer a.free(bytes);
            var decoded = try contracts.decodeOwned(contracts.tool_construction.Input, a, bytes);
            defer decoded.deinit();
            var descriptor = try data.schema.decode(a, decoded.value.schema.bytes);
            defer descriptor.deinit();
            try data.schema.validateValue(a, descriptor.descriptor, decoded.value.value.bytes);
            const value = try workspacePublishValue(
                self,
                a,
                task_id,
                try store(self).putObject(decoded.value.schema.bytes),
                try store(self).putObject(decoded.value.value.bytes),
                .{ .kind = .acquisition, .sources = .{ .items = &.{} }, .frozen_input = ref },
            );
            return value;
        }
        fn materializeDerivedContext(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            materialize: @FieldType(wc.Context, "materialize"),
        ) !state.Reference {
            var sources: std.ArrayList(state.Reference) = .empty;
            defer sources.deinit(a);
            for (materialize.sources.items) |ref| try sources.append(
                a,
                (try workspaceValueReference(self, a, task_id, ref)).artifact,
            );
            const schema: state.Reference, const payload: state.Reference =
                switch (materialize.input.value) {
                    .reference => |ref| inner: {
                        const origin = try workspaceValueReference(self, a, task_id, ref);
                        if (sources.items.len == 0) return origin.artifact;
                        try sources.append(a, origin.artifact);
                        break :inner .{ origin.schema, origin.value };
                    },
                    .inline_json => |inline_value| inner: {
                        const schema =
                            try workspaceOwnedDescriptor(self, a, task_id, inline_value.schema);
                        const descriptor = try store(self).object(a, schema, null);
                        defer a.free(descriptor);
                        const text = inline_value.json_text.bytes;
                        var parsed = try json.parse(a, text, .{
                            .bytes = text.len,
                            .depth = text.len,
                            .tokens = text.len,
                            .members = text.len,
                        });
                        defer parsed.deinit();
                        const bytes = try @import("../dynamic_values.zig").encode(
                            a,
                            descriptor,
                            parsed.value,
                        );
                        defer a.free(bytes);
                        break :inner .{ schema, try store(self).putObject(bytes) };
                    },
                };
            return try workspacePublishValue(
                self,
                a,
                task_id,
                schema,
                payload,
                .{
                    .kind = if (sources.items.len == 0) .hypothesis else .judgment,
                    .sources = .{ .items = sources.items },
                },
            );
        }
        fn prepareWorkspaceContext(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            command: wc.Context,
        ) !void {
            switch (command) {
                .materialize => |materialize| switch (materialize.input) {
                    .value => |input| {
                        for (materialize.sources.items) |ref| _ =
                            try workspaceValueReference(self, a, task_id, ref);
                        switch (input) {
                            .reference => |ref| _ =
                                try workspaceValueReference(self, a, task_id, ref),
                            .inline_json => |value| _ = try workspaceOwnedDescriptor(
                                self,
                                a,
                                task_id,
                                value.schema,
                            ),
                        }
                    },
                    .guest_view => |selection| {
                        if (materialize.sources.items.len != 0) return error.InvalidMaterialization;
                        const observed = try freezeWorkspaceWork(
                            self,
                            a,
                            task_id,
                            selection.expected.work,
                            false,
                        );
                        try inspectionSelection(observed.work, selection);
                        var prepared = try inspectionRuntime(self, a, observed.work);
                        prepared.deinit();
                    },
                    .snapshot, .authorized_input, .semantic_source => {},
                },
                .select => |selection| for (selection.values.items) |ref| {
                    _ = try workspaceValueReference(self, a, task_id, ref);
                },
                else => return error.InvalidState,
            }
        }
        fn prepareSemanticValue(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            selection: @FieldType(wc.Materialization, "semantic_source"),
        ) !PreparedSemanticValue {
            const request: wc.Command = .{ .program = .{ .inspect = .{
                .target = .{ .semantic_source = .{
                    .subject = selection.subject,
                    .section = .{ .summary = .{} },
                } },
                .page = .{},
            } } };
            const basis_bytes = try workspaceReadBasis(self, a, parent, request);
            defer a.free(basis_bytes);
            var basis = try contracts.decodeOwned(workspace.ReadObservation, a, basis_bytes);
            errdefer basis.deinit();
            const resolved =
                try semanticRuntime(self, a, parent.id, selection.subject, basis.value);
            var admitted = resolved.admitted;
            defer admitted.deinit();
            const runtime = try admitted.encode(a);
            errdefer a.free(runtime);
            const derived =
                try renderSemanticValue(self, a, &admitted, selection.module, selection.references);
            return .{
                .schema = derived.schema,
                .value = derived.value,
                .runtime = runtime,
                .basis = basis,
                .origin = .{
                    .selection = selection,
                    .basis = basis.value,
                    .guest = resolved.guest,
                    .runtime = .{ .digest = storage.digest(runtime), .bytes = runtime.len },
                },
            };
        }
        fn semanticValueBytes(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            origin: workspace.SemanticSource,
        ) !construction.SemanticValue {
            var resolved =
                try semanticRuntime(self, a, task_id, origin.selection.subject, origin.basis);
            defer resolved.deinit();
            if (!std.meta.eql(origin.guest, resolved.guest) or
                !std.meta.eql(origin.runtime.digest, resolved.admitted.identity))
            {
                return error.InvalidArchive;
            }
            const bytes = try store(self).object(a, origin.runtime, null);
            defer a.free(bytes);
            var retained = try kosmos.RuntimeArtifact.init(a, bytes, origin.runtime.digest);
            defer retained.deinit();
            return renderSemanticValue(
                self,
                a,
                &retained,
                origin.selection.module,
                origin.selection.references,
            );
        }
        pub fn workspaceValueReference(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            ref: wc.Ref,
        ) !WorkspaceValueReference {
            return workspaceValueReferenceIn(self, a, task_id, ref, null);
        }
        pub fn workspaceValueReferenceIn(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            ref: wc.Ref,
            checked: ?*Snapshots.SnapshotValidation,
        ) !WorkspaceValueReference {
            const id = try wp.identity(ref, .value);
            const key = try workspaceContentCustody(a, task_id, id);
            var saved =
                try record(self, workspace.Value, a, "workspace_value", key, task_id);
            defer saved.deinit();
            try validateWorkspaceValueIdentity(a, task_id, key, id, saved.value);
            if (saved.value.derivation.semantic_source) |origin| {
                try validateSemanticValueOrigin(self, a, task_id, id, saved.value, checked, origin);
            } else if (saved.value.derivation.inspection) |origin| {
                try validateInspectionValueOrigin(self, a, task_id, saved.value, origin);
            } else if (saved.value.derivation.kind == .inspection) return error.InvalidArchive;
            if (saved.value.derivation.acquisition) |origin| {
                try validateAcquiredValueOrigin(self, a, task_id, saved.value, origin);
            } else if (saved.value.derivation.frozen_input) |frozen_ref| {
                try validateFrozenValueOrigin(self, a, task_id, saved.value, frozen_ref);
            } else if (saved.value.derivation.kind == .acquisition) return error.CorruptState;
            if (saved.value.derivation.delegation != null or saved.value.derivation.capture != null)
                try validateDelegatedValue(self, a, task_id, saved.value);
            const origin = saved.value.derivation;
            if (origin.program == null and
                origin.work == null and
                origin.acquisition == null and
                origin.frozen_input == null and
                origin.delegation == null and
                origin.capture == null and
                origin.inspection == null and
                origin.semantic_source == null)
            {
                const expected: @TypeOf(origin.kind) =
                    if (origin.sources.items.len == 0) .hypothesis else .judgment;
                if (origin.kind != expected) return error.InvalidArchive;
            }
            return .{
                .artifact = saved.value.artifact,
                .schema = saved.value.description.schema,
                .value = saved.value.description.value,
                .provenance = saved.value.description.provenance,
            };
        }
        fn validateSemanticValueOrigin(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
            saved: workspace.Value,
            checked: ?*Snapshots.SnapshotValidation,
            origin: workspace.SemanticSource,
        ) !void {
            const d = saved.derivation;
            if (d.kind != .inspection or d.sources.items.len != 0 or d.program != null or
                d.work != null or d.acquisition != null or d.frozen_input != null or
                d.delegation != null or d.capture != null or d.inspection != null)
            {
                return error.InvalidArchive;
            }
            const fact: Snapshots.SnapshotValidation.Key = .{
                .kind = .semantic_source,
                .task = task_id,
                .identity = id,
            };
            const facts =
                if (checked) |context|
                    if (context.semantic_sources) context else null
                else
                    null;
            if (facts == null or !facts.?.facts.contains(fact)) {
                const derived = try semanticValueBytes(self, a, task_id, origin);
                defer a.free(derived.schema);
                defer a.free(derived.value);
                if (!std.meta.eql(saved.description.schema, state.Reference{
                    .digest = storage.digest(derived.schema),
                    .bytes = derived.schema.len,
                }) or !std.meta.eql(saved.description.value, state.Reference{
                    .digest = storage.digest(derived.value),
                    .bytes = derived.value.len,
                })) return error.InvalidArchive;
                if (facts) |validated| try validated.facts.put(validated.allocator, fact, .checked);
            }
        }
        fn validateInspectionValueOrigin(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            saved: workspace.Value,
            origin: workspace.Inspection,
        ) !void {
            const d = saved.derivation;
            if (d.kind != .inspection or
                d.sources.items.len != 0 or
                d.program != null or
                d.work != null or
                d.acquisition != null or
                d.frozen_input != null or
                d.delegation != null or
                d.capture != null)
                return error.InvalidArchive;
            const derived = try workspaceInspectionBytes(self, a, task_id, origin);
            defer a.free(derived.schema);
            defer a.free(derived.value);
            if (!std.meta.eql(saved.description.schema, state.Reference{
                .digest = storage.digest(derived.schema),
                .bytes = derived.schema.len,
            }) or
                !std.meta.eql(saved.description.value, state.Reference{
                    .digest = storage.digest(derived.value),
                    .bytes = derived.value.len,
                })) return error.InvalidArchive;
        }
        fn validateAcquiredValueOrigin(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            saved: workspace.Value,
            origin: workspace.SnapshotRange,
        ) !void {
            if (saved.derivation.kind != .acquisition or
                saved.derivation.sources.items.len != 0 or
                saved.derivation.program != null or
                saved.derivation.work != null or
                saved.derivation.frozen_input != null)
                return error.CorruptState;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try workspaceSnapshotAccess(parent.value, origin.snapshot);
            const derived = try workspaceSnapshotBytes(self, a, origin);
            defer a.free(derived.schema);
            defer a.free(derived.value);
            if (!std.meta.eql(saved.description.schema, state.Reference{
                .digest = storage.digest(derived.schema),
                .bytes = derived.schema.len,
            }) or !std.meta.eql(saved.description.value, state.Reference{
                .digest = storage.digest(derived.value),
                .bytes = derived.value.len,
            })) return error.CorruptState;
        }
        fn validateFrozenValueOrigin(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            saved: workspace.Value,
            frozen_ref: state.Reference,
        ) !void {
            if (saved.derivation.kind != .acquisition or saved.derivation.sources.items.len != 0 or
                saved.derivation.program != null or saved.derivation.work != null)
                return error.CorruptState;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try workspaceSnapshotAccess(parent.value, frozen_ref);
            const bytes = try store(self).object(a, frozen_ref, null);
            defer a.free(bytes);
            var input_value =
                try contracts.decodeOwned(contracts.tool_construction.Input, a, bytes);
            defer input_value.deinit();
            if (!std.meta.eql(saved.description.schema, state.Reference{
                .digest = storage.digest(input_value.value.schema.bytes),
                .bytes = input_value.value.schema.bytes.len,
            }) or !std.meta.eql(saved.description.value, state.Reference{
                .digest = storage.digest(input_value.value.value.bytes),
                .bytes = input_value.value.value.bytes.len,
            })) return error.CorruptState;
            var descriptor = try data.schema.decode(a, input_value.value.schema.bytes);
            defer descriptor.deinit();
            try data.schema.validateValue(a, descriptor.descriptor, input_value.value.value.bytes);
        }
        fn validateWorkspaceValueIdentity(
            a: std.mem.Allocator,
            task_id: state.TaskId,
            key: state.Digest,
            id: state.Digest,
            saved: workspace.Value,
        ) !void {
            if (!std.meta.eql(saved.task, task_id) or !std.meta.eql(saved.id, key) or
                !std.meta.eql(saved.artifact.digest, id))
                return error.CorruptState;
            const encoded =
                try contracts.encodeOwned(workspace.ValueArtifact, a, saved.description);
            defer a.free(encoded);
            const provenance = try contracts.encodeOwned(workspace.Derivation, a, saved.derivation);
            defer a.free(provenance);
            if (saved.description.version != 1 or !std.meta.eql(storage.digest(encoded), id) or
                encoded.len != saved.artifact.bytes or !std.meta.eql(
                storage.digest(provenance),
                saved.description.provenance.digest,
            )) return error.CorruptState;
        }
    };
}
