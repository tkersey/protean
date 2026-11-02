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
const archive_api = @import("../archive.zig");
const task_types = @import("types.zig");
const CompilerFact = task_types.CompilerFact;
const SemanticReadSubject = task_types.SemanticReadSubject;
const SemanticRendering = task_types.SemanticRendering;
const operation = task_types.operation;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const requireSemanticPolicy = Observations.requireSemanticPolicy;
        const runtimeCompilerFact = Programs.runtimeCompilerFact;
        const store = Lifecycle.store;
        const validateCandidateCompiler = Observations.validateCandidateCompiler;
        const validateCompilerOutput = Builds.validateCompilerOutput;
        const validateProgramCompiler = Programs.validateProgramCompiler;
        const validateRuntimeCompiler = Programs.validateRuntimeCompiler;
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Builds = @import("workspace_builds.zig").Operations(Types, Self);
        const Observations = @import("workspace_observations.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        pub const CompilerFacts = compilerFactsType();
        fn compilerFactsType() type {
            return struct {
                allocator: std.mem.Allocator,
                entries: std.AutoHashMapUnmanaged(CompilerFact, void) = .empty,
                sources: std.AutoHashMapUnmanaged(state.Digest, []u8) = .empty,
                values: std.AutoHashMapUnmanaged(state.Digest, construction.SemanticValue) = .empty,

                pub fn deinit(facts: *@This()) void {
                    var sources = facts.sources.valueIterator();
                    while (sources.next()) |bytes| facts.allocator.free(bytes.*);
                    facts.sources.deinit(facts.allocator);
                    var semantic_values = facts.values.valueIterator();
                    while (semantic_values.next()) |value| {
                        facts.allocator.free(value.schema);
                        facts.allocator.free(value.value);
                    }
                    facts.values.deinit(facts.allocator);
                    facts.entries.deinit(facts.allocator);
                }
            };
        }
        fn semanticRenderingKey(
            a: std.mem.Allocator,
            runtime: *const kosmos.RuntimeArtifact,
            selection: SemanticRendering,
        ) !state.Digest {
            const runtime_bytes = try runtime.encode(a);
            defer a.free(runtime_bytes);
            const Key = struct { runtime: state.Reference, selection: SemanticRendering };
            const bytes = try contracts.encodeOwned(Key, a, .{
                .runtime = compilerReference(runtime_bytes),
                .selection = selection,
            });
            defer a.free(bytes);
            return storage.digest(bytes);
        }
        pub fn renderSemanticSource(
            self: *Self,
            a: std.mem.Allocator,
            runtime: *const kosmos.RuntimeArtifact,
            guest: state.Reference,
            section: wc.SemanticSection,
            page: wc.Page,
        ) !json.Value {
            const key = try semanticRenderingKey(a, runtime, .{ .source = .{
                .guest = guest,
                .section = section,
                .page = page,
            } });
            if (self.compiler_facts) |facts| if (facts.sources.get(key)) |bytes| {
                return std.json.parseFromSliceLeaky(json.Value, a, bytes, .{
                    .allocate = .alloc_always,
                    .parse_numbers = false,
                });
            };
            if (store(self).transaction) return error.CompilerPreparationRequired;
            const result = try construction.semanticSource(a, runtime, guest, section, page);
            if (self.compiler_facts) |facts| {
                const bytes = try json.canonical(facts.allocator, result);
                errdefer facts.allocator.free(bytes);
                try facts.sources.put(facts.allocator, key, bytes);
            }
            return result;
        }
        pub fn renderConsumer(
            self: *Self,
            a: std.mem.Allocator,
            bytes: []const u8,
            derived: bool,
            site: @import("horos").source.consumer.Site,
            page: wc.Page,
        ) !json.Value {
            const Key = struct {
                contract: contracts.Utf8,
                source: state.Reference,
                derived: bool,
                site: @import("horos").source.consumer.Site,
                page: wc.Page,
            };
            const key_bytes = try contracts.encodeOwned(Key, a, .{
                .contract = .{ .bytes = "protean-consumer-inspection/1" },
                .source = compilerReference(bytes),
                .derived = derived,
                .site = site,
                .page = page,
            });
            defer a.free(key_bytes);
            const key = storage.digest(key_bytes);
            if (self.compiler_facts) |facts| if (facts.sources.get(key)) |cached|
                return std.json.parseFromSliceLeaky(json.Value, a, cached, .{
                    .allocate = .alloc_always,
                    .parse_numbers = false,
                });
            if (store(self).transaction) return error.CompilerPreparationRequired;
            const result = try construction.inspectConsumer(a, bytes, derived, site, page);
            if (self.compiler_facts) |facts| {
                const rendered = try json.canonical(facts.allocator, result);
                errdefer facts.allocator.free(rendered);
                try facts.sources.put(facts.allocator, key, rendered);
            }
            return result;
        }
        pub fn renderSemanticValue(
            self: *Self,
            a: std.mem.Allocator,
            runtime: *const kosmos.RuntimeArtifact,
            module: wc.SemanticModule,
            references: bool,
        ) !construction.SemanticValue {
            const key = try semanticRenderingKey(a, runtime, .{ .value = .{
                .module = module,
                .references = references,
            } });
            if (self.compiler_facts) |facts| if (facts.values.get(key)) |value| {
                const schema = try a.dupe(u8, value.schema);
                errdefer a.free(schema);
                return .{ .schema = schema, .value = try a.dupe(u8, value.value) };
            };
            if (store(self).transaction) return error.CompilerPreparationRequired;
            const result = try construction.semanticModuleValue(a, runtime, module, references);
            errdefer {
                a.free(result.schema);
                a.free(result.value);
            }
            if (self.compiler_facts) |facts| {
                const schema = try facts.allocator.dupe(u8, result.schema);
                errdefer facts.allocator.free(schema);
                const value = try facts.allocator.dupe(u8, result.value);
                errdefer facts.allocator.free(value);
                try facts.values.put(facts.allocator, key, .{ .schema = schema, .value = value });
            }
            return result;
        }
        pub fn compilerFact(self: *Self, fact: CompilerFact) !bool {
            if (self.compiler_facts) |facts| if (facts.entries.contains(fact)) return true;
            if (store(self).transaction) return error.CompilerPreparationRequired;
            return false;
        }
        pub fn retainCompilerFact(self: *Self, fact: CompilerFact) !void {
            if (self.compiler_facts) |facts| try facts.entries.put(facts.allocator, fact, {});
        }
        pub fn compilerReference(bytes: []const u8) state.Reference {
            return .{ .digest = storage.digest(bytes), .bytes = bytes.len };
        }
        fn prepareSemanticRead(
            self: *Self,
            a: std.mem.Allocator,
            manifest: state.Archive,
            source: anytype,
            parent: state.Task,
            selection: @FieldType(wc.InspectionTarget, "semantic_source"),
            page: wc.Page,
            basis: workspace.ReadObservation,
        ) !void {
            const subject = switch (selection.subject) {
                .runtime => |selected| try semanticRuntimeSubject(
                    a,
                    manifest,
                    source,
                    parent,
                    selected,
                ),
                .work => try semanticWorkSubject(a, manifest, source, parent, basis),
                .controller => try semanticControllerSubject(a, manifest, source, parent, basis),
            };
            var admitted = if (subject.runtime) |ref|
                try kosmos.RuntimeArtifact.init(a, try source.object(a, ref, null), ref.digest)
            else
                try self.program.retainRuntime();
            defer admitted.deinit();
            _ = try renderSemanticSource(
                self,
                a,
                &admitted,
                subject.guest,
                selection.section,
                page,
            );
        }
        fn semanticRuntimeSubject(
            a: std.mem.Allocator,
            manifest: state.Archive,
            source: anytype,
            parent: state.Task,
            selected: anytype,
        ) !SemanticReadSubject {
            var runtime: ?state.Reference = null;
            var guest: state.Reference = undefined;

            const key = try workspace.custodyId(a, parent.id, try wp.identity(selected, .runtime));
            const ref = archive_api.record(manifest, .workspace_runtime, key) orelse
                return error.InvalidArchive;
            var saved =
                try contracts.decodeOwned(workspace.Runtime, a, try source.object(a, ref, null));
            defer saved.deinit();
            runtime = saved.value.artifact;
            const program_key = try workspace.custodyId(a, parent.id, saved.value.program);
            const program_ref = archive_api.record(manifest, .workspace_program, program_key) orelse
                return error.InvalidArchive;
            var program = try contracts.decodeOwned(
                workspace.Program,
                a,
                try source.object(a, program_ref, null),
            );
            defer program.deinit();
            guest = program.value.description.image;

            return .{ .runtime = runtime, .guest = guest };
        }
        fn semanticWorkSubject(
            a: std.mem.Allocator,
            manifest: state.Archive,
            source: anytype,
            parent: state.Task,
            basis: workspace.ReadObservation,
        ) !SemanticReadSubject {
            var runtime: ?state.Reference = null;
            var guest: state.Reference = undefined;

            if (basis != .works or basis.works.works.items.len == 0)
                return error.InvalidArchive;
            const observed = basis.works.works.items[0] orelse return error.InvalidArchive;
            runtime = observed.work.runtime;
            const key = try workspace.custodyId(a, parent.id, observed.work.program);
            const ref = archive_api.record(manifest, .workspace_program, key) orelse
                return error.InvalidArchive;
            var program =
                try contracts.decodeOwned(workspace.Program, a, try source.object(a, ref, null));
            defer program.deinit();
            guest = program.value.description.image;

            return .{ .runtime = runtime, .guest = guest };
        }
        fn semanticControllerSubject(
            a: std.mem.Allocator,
            manifest: state.Archive,
            source: anytype,
            parent: state.Task,
            basis: workspace.ReadObservation,
        ) !SemanticReadSubject {
            var runtime: ?state.Reference = null;
            var guest: state.Reference = undefined;

            if (basis != .controller) return error.InvalidArchive;
            runtime = basis.controller.runtime;
            guest = parent.image;
            if (basis.controller.binding) |id| {
                const ref = archive_api.record(manifest, .controller_binding, id) orelse
                    return error.InvalidArchive;
                var binding = try contracts.decodeOwned(
                    state.ControllerBinding,
                    a,
                    try source.object(a, ref, null),
                );
                defer binding.deinit();
                guest = binding.value.image;
            }

            return .{ .runtime = runtime, .guest = guest };
        }
        fn prepareSemanticRenderings(self: *Self, manifest: state.Archive, source: anytype) !void {
            for (manifest.records.items) |row| {
                try prepareSemanticRenderingRow(self, manifest, source, row);
            }
        }
        fn prepareSemanticRenderingRow(
            self: *Self,
            manifest: state.Archive,
            source: anytype,
            row: state.ArchiveRecord,
        ) !void {
            if (row.kind != .workspace_value and row.kind != .workspace_reply) return;
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const bytes = try source.object(a, row.body, null);
            if (row.kind == .workspace_value) {
                return prepareSemanticValueRendering(self, a, source, bytes);
            }

            try prepareSemanticReplyRendering(self, a, manifest, source, bytes);
        }
        fn prepareSemanticValueRendering(
            self: *Self,
            a: std.mem.Allocator,
            source: anytype,
            bytes: []const u8,
        ) !void {
            var saved = try contracts.decodeOwned(workspace.Value, a, bytes);
            defer saved.deinit();
            const origin = saved.value.derivation.semantic_source orelse return;
            var admitted = try kosmos.RuntimeArtifact.init(
                a,
                try source.object(a, origin.runtime, null),
                origin.runtime.digest,
            );
            defer admitted.deinit();
            const rendered = try renderSemanticValue(
                self,
                a,
                &admitted,
                origin.selection.module,
                origin.selection.references,
            );
            a.free(rendered.schema);
            a.free(rendered.value);
            return;
        }
        fn prepareSemanticReplyRendering(
            self: *Self,
            a: std.mem.Allocator,
            manifest: state.Archive,
            source: anytype,
            bytes: []const u8,
        ) !void {
            var saved = try contracts.decodeOwned(workspace.ReplyObservation, a, bytes);
            defer saved.deinit();
            if (saved.value.evidence != .read) return;
            var request = try data.invocation.decode(
                data.invocation.Request,
                a,
                try source.object(a, saved.value.request, null),
            );
            defer request.deinit();
            const entry =
                try self.handlers.resolve(request.value, request.value.binding.program_identity);
            const authorize = entry.declaration.workspace orelse return error.InvalidArchive;
            var parent =
                try contracts.decodeOwned(state.Task, a, try source.object(a, manifest.task, null));
            defer parent.deinit();
            const read = struct {
                fn object(
                    context: *anyopaque,
                    allocator: std.mem.Allocator,
                    ref: state.Reference,
                    limit: usize,
                ) ![]u8 {
                    const selected: @TypeOf(source) = @ptrCast(@alignCast(context));
                    return selected.object(allocator, ref, limit);
                }
            }.object;
            const authorized_bytes = try authorize(.{
                .allocator = a,
                .task = parent.value.id,
                .tenant = parent.value.tenant.bytes,
                .profile = self.profile.bytes,
                .application = self.application.image_identity,
                .resources = parent.value.resources.items,
                .objects = .validating(source, read),
            }, request.value.binding.payload);
            var authorized = try contracts.decodeOwned(workspace.Authorized, a, authorized_bytes);
            defer authorized.deinit();
            const command = authorized.value.command;
            if (command != .program or command.program != .inspect) return;
            const inspected = command.program.inspect;
            if (inspected.target == .semantic_source) {
                try prepareSemanticRead(
                    self,
                    a,
                    manifest,
                    source,
                    parent.value,
                    inspected.target.semantic_source,
                    inspected.page,
                    saved.value.evidence.read,
                );
            } else if (inspected.target == .consumer) {
                try prepareConsumerRendering(self, a, manifest, source, parent.value, inspected);
            }
        }
        fn prepareConsumerRendering(
            self: *Self,
            a: std.mem.Allocator,
            manifest: state.Archive,
            source: anytype,
            parent: state.Task,
            inspected: @FieldType(wc.Program, "inspect"),
        ) !void {
            const selected = inspected.target.consumer;
            const key =
                try workspace.custodyId(a, parent.id, try wp.identity(selected.program, .program));
            const ref = archive_api.record(manifest, .workspace_program, key) orelse
                return error.InvalidArchive;
            var program =
                try contracts.decodeOwned(workspace.Program, a, try source.object(a, ref, null));
            defer program.deinit();
            const artifact = program.value.description;
            if (artifact.source_kind != .source_records and
                artifact.source_kind != .source_derivation)
                return error.UnsupportedSource;
            _ = try renderConsumer(self, a, try source.object(
                a,
                artifact.source,
                null,
            ), artifact.source_kind == .source_derivation, .{
                .function = selected.function,
                .binding = selected.binding,
            }, inspected.page);
        }
        pub fn prepareCompilerFacts(self: *Self, manifest: state.Archive, source: anytype) !void {
            if (store(self).transaction or self.compiler_facts == null)
                return error.InvalidState;
            try prepareCompilerOrigin(self, manifest, source);
            const Reuse = @import("../reuse_state.zig");
            var origins: Reuse.Origins = .{ .a = self.allocator };
            defer origins.deinit();
            try origins.scanPublications(source, manifest);
            var index: usize = 0;
            while (index < origins.references.count()) : (index += 1) {
                const ref = origins.references.keys()[index];
                const bytes = try source.object(self.allocator, ref, null);
                defer self.allocator.free(bytes);
                var definition = try contracts.decodeOwned(
                    @import("../reuse_state.zig").Definition,
                    self.allocator,
                    bytes,
                );
                defer definition.deinit();
                try prepareCompilerOrigin(self, definition.value.origin, source);
                try origins.scanPublications(source, definition.value.origin);
            }
        }
        fn prepareCompilerOrigin(self: *Self, manifest: state.Archive, source: anytype) !void {
            try validateArchiveRuntimePolicies(self, manifest, source);
            try prepareArchiveCompilerEvents(self, manifest, source);
            try prepareArchiveCompilerCaptures(self, manifest, source);
            try prepareArchiveCompilerRecords(self, manifest, source);
            try prepareSemanticRenderings(self, manifest, source);
        }
        fn validateArchiveRuntimePolicies(
            self: *Self,
            manifest: state.Archive,
            source: anytype,
        ) !void {
            for (manifest.records.items) |row| {
                if (row.kind != .workspace_runtime) continue;
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const a = arena.allocator();
                var saved = try contracts.decodeOwned(
                    workspace.Runtime,
                    a,
                    try source.object(a, row.body, null),
                );
                defer saved.deinit();
                if (saved.value.validation) |validation| try requireSemanticPolicy(
                    self,
                    validation.root,
                    validation.checker.bytes,
                );
            }
        }
        fn prepareArchiveCompilerEvents(
            self: *Self,
            manifest: state.Archive,
            source: anytype,
        ) !void {
            for (manifest.events.items) |row| {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const a = arena.allocator();
                var event_value =
                    try contracts.decodeOwned(state.Event, a, try source.object(a, row.body, null));
                defer event_value.deinit();
                const reference = event_value.value.workspace_command orelse continue;
                var command = try contracts.decodeOwned(
                    workspace.PublicationCommand,
                    a,
                    try source.object(a, reference, null),
                );
                defer command.deinit();
                if (command.value != .semantic) continue;
                const selected = command.value.semantic;
                try validateCompilerOutput(
                    self,
                    event_value.value.task,
                    try source.object(a, selected.input, null),
                    try source.object(a, selected.output, null),
                );
            }
        }
        fn prepareArchiveCompilerCaptures(
            self: *Self,
            manifest: state.Archive,
            source: anytype,
        ) !void {
            for (manifest.records.items) |row| {
                if (row.kind != .capture) continue;
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const a = arena.allocator();
                var captured = try contracts.decodeOwned(
                    state.Capture,
                    a,
                    try source.object(a, row.body, null),
                );
                defer captured.deinit();
                const output = captured.value.response orelse continue;
                const attempt_ref = archive_api.record(manifest, .attempt, row.id) orelse
                    return error.InvalidArchive;
                var attempt = try contracts.decodeOwned(
                    state.Attempt,
                    a,
                    try source.object(a, attempt_ref, null),
                );
                defer attempt.deinit();
                if (attempt.value.operation != .workspace_build) continue;
                try validateCompilerOutput(
                    self,
                    attempt.value.task,
                    try source.object(a, captured.value.request, null),
                    try source.object(a, output, null),
                );
            }
        }
        fn prepareArchiveCompilerRecords(
            self: *Self,
            manifest: state.Archive,
            source: anytype,
        ) !void {
            for (manifest.records.items) |row| {
                if (row.kind != .workspace_program and row.kind != .workspace_candidate and
                    row.kind != .workspace_runtime)
                    continue;
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const a = arena.allocator();
                const bytes = try source.object(a, row.body, null);
                switch (row.kind) {
                    .workspace_program => {
                        var saved = try contracts.decodeOwned(workspace.Program, a, bytes);
                        defer saved.deinit();
                        if (comptime @TypeOf(source) == *storage.Store) {
                            if (self.checked_workspace_programs.get(
                                saved.value.artifact.digest,
                            ) == store(self).integrity_epoch) continue;
                        }
                        try validateProgramCompiler(self, a, saved.value, source);
                    },
                    .workspace_candidate => {
                        var saved = try contracts.decodeOwned(workspace.Candidate, a, bytes);
                        defer saved.deinit();
                        try validateCandidateCompiler(self, a, saved.value, source);
                    },
                    .workspace_runtime => {
                        var saved = try contracts.decodeOwned(workspace.Runtime, a, bytes);
                        defer saved.deinit();
                        if (comptime @TypeOf(source) == *storage.Store) {
                            if (self.checked_workspace_runtimes.get(
                                try runtimeCompilerFact(
                                    a,
                                    saved.value.artifact,
                                    saved.value.validation,
                                ),
                            ) == store(self).integrity_epoch) continue;
                        }
                        const code = try source.object(a, saved.value.artifact, null);
                        var admitted =
                            try kosmos.RuntimeArtifact.init(a, code, saved.value.artifact.digest);
                        defer admitted.deinit();
                        try validateRuntimeCompiler(
                            self,
                            a,
                            saved.value.artifact,
                            saved.value.validation,
                            &admitted,
                            source,
                        );
                    },
                    else => unreachable,
                }
            }
        }
    };
}
