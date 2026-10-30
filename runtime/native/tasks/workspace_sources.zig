const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const storage = @import("../store.zig");
const json = @import("../json.zig");
const values = @import("../values.zig");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const WorkspaceSource = task_types.WorkspaceSource;
const WorkspaceValueReference = task_types.WorkspaceValueReference;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const record = Records.record;
        const store = Lifecycle.store;
        const workspaceContentCustody = Programs.workspaceContentCustody;
        const workspacePayloadPage = Observations.workspacePayloadPage;
        const workspaceValueReference = Contexts.workspaceValueReference;
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Contexts = @import("workspace_contexts.zig").Operations(Types, Self);
        const Observations = @import("workspace_observations.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        pub fn workspaceSource(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            ref: wc.Ref,
        ) ![]u8 {
            return workspaceBuildSource(self, a, task_id, ref, .source_records);
        }
        pub fn workspaceBuildSource(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            ref: wc.Ref,
            kind: wc.SourceKind,
        ) ![]u8 {
            if (ref.kind == .value) {
                const source = try workspaceValueReference(self, a, task_id, ref);
                return workspaceSourceByKind(self, a, source, kind);
            }
            return switch (try resolveWorkspaceSource(self, a, task_id, ref)) {
                .text => |text| text,
                .value => |source| workspaceSourceByKind(self, a, source, kind),
            };
        }
        fn workspaceSourceByKind(
            self: *Self,
            a: std.mem.Allocator,
            source: WorkspaceValueReference,
            kind: wc.SourceKind,
        ) ![]u8 {
            const records = @import("../source_records.zig");
            return switch (kind) {
                .source_records => workspaceSourceValue(self, records.Document, a, source),
                .source_derivation => workspaceSourceValue(
                    self,
                    records.DerivationDocument,
                    a,
                    source,
                ),
                .component_recipe => error.SchemaMismatch,
            };
        }
        fn workspaceSourceValue(
            self: *Self,
            comptime Document: type,
            a: std.mem.Allocator,
            source: WorkspaceValueReference,
        ) ![]u8 {
            const records = @import("../source_records.zig");
            const schema = try values.schemaBytes(Document, a);
            defer a.free(schema);
            if (!std.meta.eql(source.schema, state.Reference{
                .digest = storage.digest(schema),
                .bytes = schema.len,
            })) return error.SchemaMismatch;
            const bytes = try store(self).object(a, source.value, null);
            defer a.free(bytes);
            var document = try contracts.decodeOwned(Document, a, bytes);
            defer document.deinit();
            if (document.value.version != 1) return error.UnsupportedVersion;
            return records.encodeRecord(Document, a, document.value);
        }
        pub fn workspaceSourcePage(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            ref: wc.Ref,
            requested: wc.Page,
        ) !json.Value {
            return switch (try resolveWorkspaceSource(self, a, task_id, ref)) {
                .text => |text| blk: {
                    defer a.free(text);
                    break :blk try wp.page(a, text, requested);
                },
                .value => |value| try workspacePayloadPage(
                    self,
                    a,
                    value.schema,
                    value.value,
                    requested,
                ),
            };
        }
        fn resolveWorkspaceSource(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            ref: wc.Ref,
        ) !WorkspaceSource {
            // Resolve and authorize before choosing complete text or a bounded
            // projection. Frozen typed inputs keep their compact representation.
            const id = try wp.identity(ref, .source);
            if (try resolveAcquiredSource(self, a, task_id, id)) |source| return source;
            if (try resolveProgramSource(self, a, task_id, id)) |source| return source;
            if (try resolveCandidateSource(self, a, task_id, id)) |source| return source;
            return error.ArtifactUnavailable;
        }
        fn resolveAcquiredSource(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
        ) !?WorkspaceSource {
            var acquired = try store(self).database.prepare(
                "SELECT id FROM records WHERE task=? AND kind='workspace_value' ORDER BY id",
                &.{.{ .blob = &task_id }},
            );
            defer acquired.deinit();
            while (try acquired.step() == .row) {
                const key = try acquired.bytes(0);
                if (key.len != 32) return error.CorruptState;
                var record_value =
                    try record(self, workspace.Value, a, "workspace_value", key[0..32].*, task_id);
                defer record_value.deinit();
                if (!std.meta.eql(record_value.value.description.provenance.digest, id)) continue;
                const checked = try workspaceValueReference(
                    self,
                    a,
                    task_id,
                    try wp.reference(a, .value, record_value.value.artifact.digest),
                );
                if (record_value.value.derivation.frozen_input != null or
                    record_value.value.derivation.semantic_source != null)
                {
                    return .{ .value = checked };
                }
                const origin = record_value.value.derivation.acquisition orelse continue;
                const bytes = try store(self).object(a, origin.snapshot, null);
                defer a.free(bytes);
                var source = try @import("../repository.zig").Snapshot.openBorrowed(a, bytes);
                defer source.deinit();
                const file = source.get(origin.path.bytes) orelse return error.CorruptState;
                if (!std.unicode.utf8ValidateSlice(file.contents.bytes)) return .{
                    .text = try json.canonical(
                        a,
                        try values.toJson(contracts.Bytes(null), a, file.contents),
                    ),
                };
                return .{ .text = try a.dupe(u8, file.contents.bytes) };
            }
            return null;
        }
        fn resolveProgramSource(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
        ) !?WorkspaceSource {
            var query = try store(self).database.prepare(
                "SELECT id FROM records WHERE task=? AND kind='workspace_program' ORDER BY id",
                &.{.{ .blob = &task_id }},
            );
            defer query.deinit();
            while (try query.step() == .row) {
                const key = try query.bytes(0);
                if (key.len != 32) return error.CorruptState;
                var program = try record(
                    self,
                    workspace.Program,
                    a,
                    "workspace_program",
                    key[0..32].*,
                    task_id,
                );
                defer program.deinit();
                if (std.meta.eql(program.value.description.source.digest, id)) return .{
                    .text = try store(self).object(a, program.value.description.source, null),
                };
            }
            return null;
        }
        fn resolveCandidateSource(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
        ) !?WorkspaceSource {
            var candidates = try store(self).database.prepare(
                "SELECT id FROM records WHERE task=? AND kind='workspace_candidate' ORDER BY id",
                &.{.{ .blob = &task_id }},
            );
            defer candidates.deinit();
            while (try candidates.step() == .row) {
                const key = try candidates.bytes(0);
                if (key.len != 32) return error.CorruptState;
                var saved = try record(
                    self,
                    workspace.Candidate,
                    a,
                    "workspace_candidate",
                    key[0..32].*,
                    task_id,
                );
                defer saved.deinit();
                if (!std.meta.eql(saved.value.description.proposal.digest, id)) continue;
                var candidate =
                    try self.workspaceCandidate(a, task_id, saved.value.artifact.digest);
                defer candidate.deinit();
                return .{ .text = try store(self).object(
                    a,
                    candidate.value.description.proposal,
                    null,
                ) };
            }
            return null;
        }
        pub fn workspaceOwnedDescriptor(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            ref: wc.Ref,
        ) !state.Reference {
            if (ref.kind != .schema and ref.kind != .provenance) return error.InvalidReference;
            const id = try wp.identity(ref, ref.kind);
            var query = try store(self).database.prepare(
                "SELECT id,kind FROM records WHERE task=? AND kind IN ('workspace" ++
                    "_program','workspace_value') ORDER BY id",
                &.{.{ .blob = &task_id }},
            );
            defer query.deinit();
            while (try query.step() == .row) {
                const key = try query.bytes(0);
                if (key.len != 32) return error.CorruptState;
                if (same(try query.bytes(1), "workspace_value")) {
                    var value = try record(
                        self,
                        workspace.Value,
                        a,
                        "workspace_value",
                        key[0..32].*,
                        task_id,
                    );
                    defer value.deinit();
                    const declared =
                        if (ref.kind == .schema)
                            value.value.description.schema
                        else
                            value.value.description.provenance;
                    if (!std.meta.eql(declared.digest, id)) continue;
                    const checked = try workspaceValueReference(
                        self,
                        a,
                        task_id,
                        try wp.reference(a, .value, value.value.artifact.digest),
                    );
                    const candidate =
                        if (ref.kind == .schema) checked.schema else checked.provenance;
                    if (std.meta.eql(candidate.digest, id)) return candidate;
                } else if (ref.kind == .schema) {
                    var saved = try record(
                        self,
                        workspace.Program,
                        a,
                        "workspace_program",
                        key[0..32].*,
                        task_id,
                    );
                    defer saved.deinit();
                    if (workspaceProgramDescriptor(saved.value.description, id) == null) continue;
                    var program =
                        try self.workspaceProgram(a, task_id, saved.value.artifact.digest);
                    defer program.deinit();
                    if (workspaceProgramDescriptor(
                        program.value.description,
                        id,
                    )) |candidate| return candidate;
                }
            }
            return error.ArtifactUnavailable;
        }
        fn workspaceProgramDescriptor(
            program: workspace.ProgramArtifact,
            id: state.Digest,
        ) ?state.Reference {
            inline for (.{ "input_schema", "result_schema", "failure_schema" }) |field| {
                const candidate = @field(program, field);
                if (std.meta.eql(candidate.digest, id)) return candidate;
            }
            for (program.controller_schemas.items) |candidate| if (std.meta.eql(
                candidate.digest,
                id,
            )) return candidate;
            for (program.ports.items) |port| inline for (.{
                "argument",
                "observation",
                "payload",
                "command",
            }) |field| {
                const candidate = @field(port, field);
                if (std.meta.eql(candidate.digest, id)) return candidate;
            };
            return null;
        }
        fn workspaceDerivationObservation(
            self: *Self,
            a: std.mem.Allocator,
            derivation: workspace.Derivation,
        ) !json.Value {
            _ = self;
            var result = json.object();
            try json.put(a, &result, "kind", json.string(@tagName(derivation.kind)));
            if (derivation.kind == .computation or derivation.kind == .trial or
                derivation.kind == .judgment or derivation.kind == .hypothesis)
            {
                try json.put(a, &result, "evidence_class", json.string("experimental"));
                try json.put(a, &result, "analysis_checker", .null);
            }
            var sources: json.Value = .{ .array = .init(a) };
            for (derivation.sources.items) |ref| try sources.array.append(
                try values.toJson(wc.Ref, a, try wp.reference(a, .value, ref.digest)),
            );
            try json.put(a, &result, "sources", sources);
            try json.put(
                a,
                &result,
                "coverage",
                json.string("No source-universe completeness is asserted by this derivation."),
            );
            if (derivation.program) |ref| try json.put(
                a,
                &result,
                "program",
                try values.toJson(wc.Ref, a, try wp.reference(a, .program, ref.digest)),
            );
            if (derivation.work) |id| try json.put(
                a,
                &result,
                "work",
                try values.toJson(wc.Ref, a, try wp.reference(a, .work, id)),
            );
            try appendDerivationAcquisition(a, &result, derivation);
            try appendDerivationInspection(a, &result, derivation);
            return result;
        }
        fn appendDerivationAcquisition(
            a: std.mem.Allocator,
            result: *json.Value,
            derivation: workspace.Derivation,
        ) !void {
            if (derivation.acquisition) |origin| {
                var projected = origin;
                projected.path.bytes = try a.dupe(u8, origin.path.bytes);
                try json.put(
                    a,
                    result,
                    "acquisition",
                    try values.toJson(workspace.SnapshotRange, a, projected),
                );
                try json.put(a, result, "complete_file", .{
                    .bool = origin.start == 0 and
                        origin.end == origin.file_bytes,
                });
            }
            if (derivation.frozen_input) |ref| try json.put(
                a,
                result,
                "frozen_input",
                try values.toJson(state.Reference, a, ref),
            );
        }
        fn appendDerivationInspection(
            a: std.mem.Allocator,
            result: *json.Value,
            derivation: workspace.Derivation,
        ) !void {
            if (derivation.inspection) |origin| {
                try json.put(
                    a,
                    result,
                    "inspection",
                    try values.toJson(wc.GuestViewSelection, a, .{
                        .level = origin.level,
                        .expected = .{
                            .work = try wp.reference(a, .work, origin.observation.work.id),
                            .execution_revision = origin.observation.work.execution_revision,
                            .control_revision = origin.observation.work.control_revision,
                        },
                        .realization_revision = origin.observation.work.realization_revision,
                        .nodes = origin.nodes,
                        .disclosure = origin.disclosure,
                    }),
                );
                try json.put(
                    a,
                    result,
                    "checkpoint",
                    try values.toJson(state.Reference, a, origin.observation.work.checkpoint),
                );
            }
            if (derivation.semantic_source) |origin| {
                try json.put(a, result, "semantic_source", try values.toJson(
                    @TypeOf(origin.selection),
                    a,
                    origin.selection,
                ));
                try json.put(a, result, "semantic_runtime", try values.toJson(
                    state.Reference,
                    a,
                    origin.runtime,
                ));
                try json.put(a, result, "guest_image", try values.toJson(
                    state.Reference,
                    a,
                    origin.guest,
                ));
            }
        }
        pub fn workspaceDerivationPage(
            self: *Self,
            a: std.mem.Allocator,
            derivation: workspace.Derivation,
            page: wc.Page,
        ) !json.Value {
            // Reuse the ordinary projection's fields, but fold its growing
            // source vector directly into the requested canonical byte range.
            var metadata = derivation;
            metadata.sources.items = &.{};
            const fields = try workspaceDerivationObservation(self, a, metadata);
            const keys = try a.dupe([]const u8, fields.object.keys());
            defer a.free(keys);
            std.mem.sort([]const u8, keys, {}, struct {
                fn less(_: void, left: []const u8, right: []const u8) bool {
                    return std.mem.lessThan(u8, left, right);
                }
            }.less);
            var output = try wp.Range.init(a, page);
            defer output.deinit(a);
            var element = std.heap.ArenaAllocator.init(a);
            defer element.deinit();
            try output.append("{");
            for (keys, 0..) |key, index| {
                if (index != 0) try output.append(",");
                try output.append(try json.canonical(a, json.string(key)));
                try output.append(":");
                if (!same(key, "sources")) {
                    try output.append(try json.canonical(a, fields.object.get(key).?));
                    continue;
                }
                try output.append("[");
                for (derivation.sources.items, 0..) |ref, i| {
                    _ = element.reset(.retain_capacity);
                    const scratch = element.allocator();
                    if (i != 0) try output.append(",");
                    try output.append(
                        try json.canonical(
                            scratch,
                            try values.toJson(
                                wc.Ref,
                                scratch,
                                try wp.reference(scratch, .value, ref.digest),
                            ),
                        ),
                    );
                }
                try output.append("]");
            }
            try output.append("}");
            return output.finish(a);
        }
        pub fn workspaceValueObservation(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
        ) !json.Value {
            const ref = try wp.reference(a, .value, id);
            const value = try workspaceValueReference(self, a, task_id, ref);
            const schema = try store(self).object(a, value.schema, null);
            defer a.free(schema);
            const bytes = try store(self).object(a, value.value, null);
            defer a.free(bytes);
            var result = json.object();
            try json.put(a, &result, "value", try values.toJson(wc.Ref, a, ref));
            try json.put(
                a,
                &result,
                "schema",
                try values.toJson(wc.Ref, a, try wp.reference(a, .schema, value.schema.digest)),
            );
            try json.put(
                a,
                &result,
                "provenance",
                try values.toJson(
                    wc.Ref,
                    a,
                    try wp.reference(a, .provenance, value.provenance.digest),
                ),
            );
            try json.put(
                a,
                &result,
                "preview",
                try @import("../dynamic_values.zig").preview(a, schema, bytes),
            );
            const provenance = try store(self).object(a, value.provenance, null);
            defer a.free(provenance);
            var derivation = try contracts.decodeOwned(workspace.Derivation, a, provenance);
            defer derivation.deinit();
            try json.put(
                a,
                &result,
                "derivation",
                try workspaceDerivationObservation(self, a, derivation.value),
            );
            if (derivation.value.acquisition != null or derivation.value.frozen_input != null or
                derivation.value.semantic_source != null)
            {
                try json.put(a, &result, "source", try values.toJson(
                    wc.Ref,
                    a,
                    try wp.reference(a, .source, value.provenance.digest),
                ));
            }
            return result;
        }
        pub fn workspaceViewObservation(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
            page: wc.Page,
        ) !json.Value {
            const key = try workspaceContentCustody(a, task_id, id);
            var saved = try record(self, workspace.View, a, "workspace_view", key, task_id);
            defer saved.deinit();
            const bytes =
                try contracts.encodeOwned(workspace.ViewArtifact, a, saved.value.description);
            defer a.free(bytes);
            if (saved.value.description.version != 1 or !std.meta.eql(saved.value.task, task_id) or
                !std.meta.eql(saved.value.id, key) or
                !std.meta.eql(saved.value.artifact.digest, id) or
                !std.meta.eql(storage.digest(bytes), id) or bytes.len != saved.value.artifact.bytes)
                return error.CorruptState;
            var result = json.object();
            try json.put(
                a,
                &result,
                "view",
                try values.toJson(wc.Ref, a, try wp.reference(a, .view, id)),
            );
            try json.put(a, &result, "coverage", json.string("selected_values_only"));
            var selection = try wp.Range.init(a, page);
            defer selection.deinit(a);
            try selection.append("[");
            var element = std.heap.ArenaAllocator.init(a);
            defer element.deinit();
            for (saved.value.description.values.items, 0..) |ref, i| {
                // Each element is independently projected and released. A
                // bounded page never retains N complete value previews.
                _ = element.reset(.retain_capacity);
                const scratch = element.allocator();
                const value = try workspaceValueReference(
                    self,
                    scratch,
                    task_id,
                    try wp.reference(scratch, .value, ref.digest),
                );
                if (!std.meta.eql(value.artifact, ref)) return error.CorruptState;
                if (i != 0) try selection.append(",");
                try selection.append(
                    try json.canonical(
                        scratch,
                        try workspaceValueObservation(self, scratch, task_id, ref.digest),
                    ),
                );
            }
            try selection.append("]");
            try json.put(a, &result, "selection", try selection.finish(a));
            try json.put(
                a,
                &result,
                "value_count",
                try json.number(a, saved.value.description.values.items.len),
            );
            return result;
        }
    };
}
