const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const kosmos = @import("kosmos");
const json = @import("../json.zig");
const values = @import("../values.zig");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const construction = @import("../program_construction.zig");
const task_types = @import("types.zig");
const CompilerFact = task_types.CompilerFact;
const SemanticRuntime = task_types.SemanticRuntime;
const Work = task_types.Work;
const cleanupComplete = task_types.cleanupComplete;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const compilerFact = Compiler.compilerFact;
        const compilerReference = Compiler.compilerReference;
        const controllerBinding = Controller.controllerBinding;
        const controllerRuntime = Controller.controllerRuntime;
        const freezeWorkspaceWork = Access.freezeWorkspaceWork;
        const record = Records.record;
        const renderConsumer = Compiler.renderConsumer;
        const renderSemanticSource = Compiler.renderSemanticSource;
        const retainCompilerFact = Compiler.retainCompilerFact;
        const store = Lifecycle.store;
        const workspaceContentCustody = Programs.workspaceContentCustody;
        const workspaceInteractionAllowed = Access.workspaceInteractionAllowed;
        const workspaceProposal = Builds.workspaceProposal;
        const workspaceRuntime = Programs.workspaceRuntime;
        const workspaceStoppedAt = Access.workspaceStoppedAt;
        const Compiler = @import("compiler_preparation.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Builds = @import("workspace_builds.zig").Operations(Types, Self);
        const Observers = @import("workspace_observers.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        pub fn requireSemanticPolicy(self: *Self, root: state.Digest, checker: []const u8) !void {
            const policy = self.profile.semantic_construction orelse
                return error.SemanticPolicyDenied;
            const root_allowed = for (policy.roots) |permitted| {
                if (std.meta.eql(permitted, root)) break true;
            } else false;
            const checker_allowed = for (policy.checkers) |permitted| {
                if (same(permitted, checker)) break true;
            } else false;
            if (!root_allowed or !checker_allowed) return error.SemanticPolicyDenied;
        }
        pub fn requireRuntimePolicy(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            reference: ?state.Reference,
        ) !void {
            const ref = reference orelse return;
            if (self.runtime_cache) |*cached| {
                if (cached.epoch == store(self).integrity_epoch and
                    std.meta.eql(cached.artifact.identity, ref.digest))
                    return requireSemanticPolicy(
                        self,
                        kosmos.RuntimeCompiler.approvedRootIdentity(&cached.artifact),
                        kosmos.RuntimeCompiler.checker_identity,
                    );
            }
            var selected = try workspaceRuntime(self, a, task_id, ref.digest, null);
            defer selected.deinit();
            try requireSemanticPolicy(
                self,
                kosmos.RuntimeCompiler.approvedRootIdentity(&selected.admitted),
                kosmos.RuntimeCompiler.checker_identity,
            );
        }
        pub fn workspaceSemanticPolicy(
            self: *Self,
            a: std.mem.Allocator,
        ) !?workspace.SemanticPolicyObservation {
            const policy = self.profile.semantic_construction orelse return null;
            const checkers = try a.alloc(state.Name, policy.checkers.len);
            for (policy.checkers, checkers) |checker, *checker_name|
                checker_name.* = .{ .bytes = checker };
            return .{
                .roots = .{ .items = policy.roots },
                .checkers = .{ .items = checkers },
                .guard = policy.guard,
            };
        }
        pub fn workspaceSemanticContract(
            self: *Self,
            a: std.mem.Allocator,
            basis: ?workspace.ReadObservation,
        ) ![]u8 {
            const selected = if (basis) |frozen| blk: {
                if (frozen != .semantic_policy) return error.InvalidArchive;
                break :blk frozen.semantic_policy.policy;
            } else try workspaceSemanticPolicy(self, a);
            defer if (basis == null) if (selected) |policy| a.free(policy.checkers.items);
            var result = json.object();
            const schema = try @import("../source_records.zig").describeRecord(
                construction.CandidateDocument,
                a,
            );
            defer a.free(schema);
            try json.put(a, &result, "contract", json.string("protean-semantic-candidate/1"));
            try json.put(a, &result, "checker_identity", json.string(
                kosmos.RuntimeCompiler.checker_identity,
            ));
            try json.put(a, &result, "proposal_schema", json.string(try a.dupe(u8, schema)));
            const indexed_schema = try @import("../source_records.zig").describeRecord(
                @import("../source_records.zig").IndexedDocument,
                a,
            );
            defer a.free(indexed_schema);
            try json.put(a, &result, "indexed_source_schema", json.string(
                try a.dupe(u8, indexed_schema),
            ));
            var roots: json.Value = .{ .array = .init(a) };
            var checkers: json.Value = .{ .array = .init(a) };
            if (selected) |policy| {
                for (policy.roots.items) |root| try roots.array.append(json.string(
                    try a.dupe(u8, &std.fmt.bytesToHex(root, .lower)),
                ));
                for (policy.checkers.items) |checker| try checkers.array.append(
                    json.string(try a.dupe(u8, checker.bytes)),
                );
            }
            try json.put(a, &result, "approved_roots", roots);
            try json.put(a, &result, "checkers", checkers);
            try json.put(a, &result, "derived_use_permitted", .{ .bool = selected != null });
            try json.put(a, &result, "controller_realization", .{ .bool = selected != null });
            try json.put(
                a,
                &result,
                "controller_realization_target",
                json.string(
                    "work.realize_controller accepts an exact cut or the current cont" ++
                        "rol.realization_target from the authenticated controller action;" ++
                        " pending outer evaluation or controller adoption must settle fir" ++
                        "st",
                ),
            );
            try json.put(a, &result, "reference_guarded", .{
                .bool = if (selected) |policy| policy.guard else false,
            });
            return json.canonical(a, result);
        }
        pub fn workspaceCandidate(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            digest: state.Digest,
        ) !contracts.Decoded(workspace.Candidate) {
            const id = try workspaceContentCustody(a, task_id, digest);
            var saved =
                try record(self, workspace.Candidate, a, "workspace_candidate", id, task_id);
            errdefer saved.deinit();
            const value = saved.value;
            const bytes =
                try contracts.encodeOwned(workspace.CandidateArtifact, a, value.description);
            defer a.free(bytes);
            if (!std.meta.eql(value.task, task_id) or !std.meta.eql(value.id, id) or
                !std.meta.eql(value.artifact, state.Reference{
                    .digest = storage.digest(bytes),
                    .bytes = bytes.len,
                }) or !std.meta.eql(value.artifact.digest, digest) or
                value.description.version != 1) return error.InvalidCandidate;
            var program = try self.workspaceProgram(a, task_id, value.program);
            defer program.deinit();
            if (!std.meta.eql(program.value.description.image, value.description.guest))
                return error.InvalidCandidate;
            const code = try store(self).object(a, value.description.code, null);
            defer a.free(code);
            var admitted = try kosmos.RuntimeArtifact.init(a, code, value.description.code.digest);
            defer admitted.deinit();
            const lineage = admitted.content.value.lineage orelse return error.InvalidCandidate;
            if (!std.meta.eql(lineage.parent, value.description.ancestor.digest))
                return error.InvalidCandidate;
            const guest = try store(self).object(a, value.description.guest, null);
            defer a.free(guest);
            const guest_image = try data.program_image.Admitted.decode(a, guest);
            defer guest_image.deinit();
            if (!std.meta.eql(
                admitted.content.value.guest,
                @as(?state.Digest, guest_image.identity()),
            ) or
                !std.meta.eql(
                    kosmos.RuntimeCompiler.approvedRootIdentity(&admitted),
                    value.description.root,
                ) or
                !same(
                    admitted.content.value.manifest.compiler.policy,
                    value.description.checker.bytes,
                ))
                return error.InvalidCandidate;
            return saved;
        }
        pub fn validateCandidateProduction(
            self: *Self,
            a: std.mem.Allocator,
            candidate: workspace.Candidate,
        ) !void {
            const d = candidate.description;
            const proposal_bytes = try store(self).object(a, d.proposal, null);
            defer a.free(proposal_bytes);
            if (d.producer) |producer| {
                const expected = try workspaceProposal(self, a, candidate.task, .{
                    .reference = try wp.reference(a, .value, producer.digest),
                });
                defer a.free(expected);
                if (!same(proposal_bytes, expected)) return error.InvalidCandidate;
            }
            try validateCandidateCompiler(self, a, candidate, store(self));
        }
        pub fn validateCandidateCompiler(
            self: *Self,
            a: std.mem.Allocator,
            candidate: workspace.Candidate,
            source: anytype,
        ) !void {
            const d = candidate.description;
            const descriptor = try contracts.encodeOwned(workspace.CandidateArtifact, a, d);
            defer a.free(descriptor);
            if (!std.meta.eql(candidate.artifact, compilerReference(descriptor)))
                return error.InvalidCandidate;
            const fact: CompilerFact = .{
                .kind = .candidate,
                .input = candidate.artifact,
                .output = d.code,
            };
            if (try compilerFact(self, fact)) return;
            const ancestor_bytes = try source.object(a, d.ancestor, null);
            defer a.free(ancestor_bytes);
            var ancestor = try kosmos.RuntimeArtifact.init(a, ancestor_bytes, d.ancestor.digest);
            defer ancestor.deinit();
            const guest_bytes = try source.object(a, d.guest, null);
            defer a.free(guest_bytes);
            const guest = try data.program_image.Admitted.decode(a, guest_bytes);
            defer guest.deinit();
            const proposal_bytes = try source.object(a, d.proposal, null);
            defer a.free(proposal_bytes);
            var document = try @import("../source_records.zig").decodeRecord(
                construction.CandidateDocument,
                a,
                proposal_bytes,
            );
            defer document.deinit();
            if (document.value.version != 1) return error.InvalidCandidate;
            const code = try kosmos.RuntimeCompiler.deriveRecord(
                a,
                &ancestor,
                guest,
                document.value.proposal,
                .{ .horos_package = @import("native_options").horos_identity },
            );
            defer a.free(code);
            if (!std.meta.eql(d.code, state.Reference{
                .digest = storage.digest(code),
                .bytes = code.len,
            })) return error.InvalidCandidate;
            try retainCompilerFact(self, fact);
        }
        pub fn workspaceCandidateObservation(
            self: *Self,
            a: std.mem.Allocator,
            candidate: workspace.Candidate,
        ) !json.Value {
            _ = self;
            var result = json.object();
            try json.put(a, &result, "candidate", try values.toJson(
                wc.Ref,
                a,
                try wp.reference(a, .candidate, candidate.artifact.digest),
            ));
            try json.put(a, &result, "construction", json.string("admitted"));
            try json.put(a, &result, "validation", json.string("not_requested"));
            try json.put(a, &result, "runtime_authority", .{ .bool = false });
            try json.put(a, &result, "program", try values.toJson(
                wc.Ref,
                a,
                try wp.reference(a, .program, candidate.program),
            ));
            try json.put(a, &result, "proposal", try values.toJson(
                wc.Ref,
                a,
                try wp.reference(a, .source, candidate.description.proposal.digest),
            ));
            try json.put(a, &result, "artifact", try values.toJson(
                workspace.CandidateArtifact,
                a,
                candidate.description,
            ));
            return result;
        }
        pub fn workspaceSemanticSource(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            selection: @FieldType(wc.InspectionTarget, "semantic_source"),
            page: wc.Page,
            basis: ?workspace.ReadObservation,
        ) !json.Value {
            var resolved = try semanticRuntime(self, a, task_id, selection.subject, basis);
            defer resolved.deinit();
            var result = try renderSemanticSource(
                self,
                a,
                &resolved.admitted,
                resolved.guest,
                selection.section,
                page,
            );
            const subject: wc.SemanticTarget = if (resolved.reference) |identity| blk: {
                const ref = try wp.reference(a, .runtime, identity);
                try json.put(a, &result, "runtime", try values.toJson(wc.Ref, a, ref));
                break :blk .{ .runtime = ref };
            } else selection.subject;
            try json.put(a, &result, "subject", try values.toJson(wc.SemanticTarget, a, subject));
            try json.put(a, &result, "runtime_identity", json.string(
                try a.dupe(u8, &std.fmt.bytesToHex(resolved.admitted.identity, .lower)),
            ));
            try json.put(a, &result, "guest_image", try values.toJson(
                state.Reference,
                a,
                resolved.guest,
            ));
            return result;
        }
        pub fn semanticRuntime(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            subject: wc.SemanticTarget,
            basis: ?workspace.ReadObservation,
        ) !SemanticRuntime {
            if (basis) |frozen| switch (subject) {
                .runtime => if (frozen != .immutable) return error.InvalidArchive,
                .controller => if (frozen != .controller) return error.InvalidArchive,
                .work => if (frozen != .works or frozen.works.works.items.len != 1 or
                    frozen.works.works.items[0] == null) return error.InvalidArchive,
            };
            switch (subject) {
                .runtime => |ref| return semanticSelectedRuntime(self, a, task_id, ref),
                .work => |selection| return semanticWorkRuntime(self, a, task_id, selection, basis),
                .controller => |selection| {
                    return semanticControllerRuntime(self, a, task_id, selection, basis);
                },
            }
        }
        fn semanticSelectedRuntime(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            ref: wc.Ref,
        ) !SemanticRuntime {
            var selected =
                try workspaceRuntime(self, a, task_id, try wp.identity(ref, .runtime), null);
            errdefer selected.admitted.deinit();
            defer selected.record.deinit();
            var program =
                try self.workspaceProgram(a, task_id, selected.record.value.program);
            defer program.deinit();
            return .{
                .admitted = selected.admitted,
                .guest = program.value.description.image,
                .reference = selected.admitted.identity,
            };
        }
        fn semanticWorkRuntime(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            selection: @FieldType(wc.SemanticTarget, "work"),
            basis: ?workspace.ReadObservation,
        ) !SemanticRuntime {
            const observed = if (basis) |frozen|
                frozen.works.works.items[0] orelse return error.ArtifactUnavailable
            else
                try freezeWorkspaceWork(self, a, task_id, selection.expected.work, false);
            const work = observed.work;
            if (!std.meta.eql(work.id, try wp.identity(selection.expected.work, .work)) or
                work.execution_revision != selection.expected.execution_revision or
                work.control_revision != selection.expected.control_revision or
                work.realization_revision != selection.realization_revision)
            {
                return error.StaleRevision;
            }
            var program = try self.workspaceProgram(a, task_id, work.program);
            defer program.deinit();
            if (work.runtime) |ref| {
                var selected =
                    try workspaceRuntime(self, a, task_id, ref.digest, work.program);
                selected.record.deinit();
                return .{
                    .admitted = selected.admitted,
                    .guest = program.value.description.image,
                    .reference = selected.admitted.identity,
                };
            }
            return .{
                .admitted = try self.program.retainRuntime(),
                .guest = program.value.description.image,
            };
        }
        fn semanticControllerRuntime(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            selection: wc.ControllerTarget,
            basis: ?workspace.ReadObservation,
        ) !SemanticRuntime {
            var saved = try self.task(a, task_id);
            defer saved.deinit();
            const parent = saved.value;
            const epoch = if (basis) |frozen| frozen.controller.epoch else parent.controller_epoch;
            const execution = if (basis) |frozen|
                frozen.controller.execution_revision
            else
                parent.execution_revision;
            const realization = if (basis) |frozen|
                frozen.controller.realization_revision
            else
                parent.realization_revision;
            switch (selection) {
                .cut => |cut| if (epoch != cut.epoch or execution != cut.execution_revision or
                    realization != cut.realization_revision) return error.StaleRevision,
                .action => |action| {
                    const id = try wp.identity(
                        .{
                            .kind = .controller,
                            .id = action.interaction,
                        },
                        .controller,
                    );
                    const interaction = if (basis) |frozen|
                        frozen.controller.interaction
                    else
                        parent.controller_interaction;
                    if (!std.meta.eql(interaction, @as(?state.Digest, id)) or
                        action.epoch != epoch or action.realization_revision != realization)
                        return error.StaleController;
                },
            }
            const binding = if (basis) |frozen| frozen.controller.binding else parent.controller;
            const guest = if (binding) |id|
                (try controllerBinding(self, a, parent, id)).image
            else
                parent.image;
            const runtime =
                if (basis) |frozen|
                    frozen.controller.runtime
                else
                    parent.controller_runtime;
            return .{
                .admitted = try controllerRuntime(self, a, task_id, guest, runtime),
                .guest = guest,
                .reference = if (runtime) |ref| ref.digest else null,
            };
        }
        pub fn workspaceConsumer(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            selected: @FieldType(wc.InspectionTarget, "consumer"),
            page: wc.Page,
        ) !json.Value {
            var program =
                try self.workspaceProgram(a, task_id, try wp.identity(selected.program, .program));
            defer program.deinit();
            const artifact = program.value.description;
            if (artifact.source_kind != .source_records and
                artifact.source_kind != .source_derivation)
                return error.UnsupportedSource;
            const bytes = try store(self).object(a, artifact.source, null);
            defer a.free(bytes);
            return renderConsumer(
                self,
                a,
                bytes,
                artifact.source_kind == .source_derivation,
                .{
                    .function = selected.function,
                    .binding = selected.binding,
                },
                page,
            );
        }
        pub fn workspaceProgramObservation(
            self: *Self,
            a: std.mem.Allocator,
            id: state.Digest,
            artifact: workspace.ProgramArtifact,
        ) !json.Value {
            var result = json.object();
            try json.put(
                a,
                &result,
                "program",
                try values.toJson(wc.Ref, a, try wp.reference(a, .program, id)),
            );
            try json.put(
                a,
                &result,
                "source",
                try values.toJson(wc.Ref, a, try wp.reference(a, .source, artifact.source.digest)),
            );
            inline for (.{ "input", "result", "failure" }) |key| {
                const ref = @field(artifact, key ++ "_schema");
                const bytes = try store(self).object(a, ref, null);
                defer a.free(bytes);
                try json.put(
                    a,
                    &result,
                    key ++ "_schema",
                    try values.toJson(wc.Ref, a, try wp.reference(a, .schema, ref.digest)),
                );
                try json.put(a, &result, key ++ "_descriptor", try wp.schema(a, bytes));
            }
            try json.put(
                a,
                &result,
                "construction_contract",
                json.string(try a.dupe(u8, artifact.construction_contract.bytes)),
            );
            try json.put(a, &result, "source_kind", json.string(@tagName(artifact.source_kind)));
            try json.put(
                a,
                &result,
                "controller",
                try values.toJson(?contracts.controller.Descriptor, a, artifact.controller),
            );
            try appendProgramExposures(a, &result, artifact);
            return result;
        }
        fn appendProgramExposures(
            a: std.mem.Allocator,
            result: *json.Value,
            artifact: workspace.ProgramArtifact,
        ) !void {
            var controller_schemas: json.Value = .{ .array = .init(a) };
            for (artifact.controller_schemas.items) |ref| try controller_schemas.array.append(
                try values.toJson(wc.Ref, a, try wp.reference(a, .schema, ref.digest)),
            );
            try json.put(a, result, "controller_schemas", controller_schemas);
            var ports: json.Value = .{ .array = .init(a) };
            for (artifact.ports.items) |port| {
                var item = json.object();
                try json.put(
                    a,
                    &item,
                    "identity",
                    json.string(try a.dupe(u8, port.identity.bytes)),
                );
                try json.put(a, &item, "class", json.string(@tagName(port.class)));
                inline for (.{ "argument", "observation", "payload", "command" }) |field| {
                    const ref = @field(port, field);
                    try json.put(
                        a,
                        &item,
                        field ++ "_schema",
                        try values.toJson(wc.Ref, a, try wp.reference(a, .schema, ref.digest)),
                    );
                }
                try ports.array.append(item);
            }
            try json.put(a, result, "ports", ports);
        }
        pub fn workspaceWorkObservation(
            self: *Self,
            a: std.mem.Allocator,
            value: workspace.Work,
        ) !json.Value {
            var parent = try self.task(a, value.task);
            defer parent.deinit();
            var observers = Observers.CurrentObservers.init(a, value.task, parent.value.event_high);
            defer observers.deinit();
            return workspaceWorkObservationIn(self, a, value, parent.value.event_high, .{
                .current = &observers,
            });
        }
        pub fn workspaceWorkObservationIn(
            self: *Self,
            a: std.mem.Allocator,
            value: workspace.Work,
            observed_at: u64,
            observers: Observers.WorkObservers,
        ) !json.Value {
            var pending: ?contracts.Decoded(occurrence.Occurrence) = null;
            defer if (pending) |*saved| saved.deinit();
            if (value.current_occurrence) |id| pending =
                try record(self, occurrence.Occurrence, a, "occurrence", id, value.task);
            return renderWorkspaceWorkObservationIn(
                self,
                a,
                value,
                if (pending) |saved| saved.value else null,
                observed_at,
                observers,
            );
        }
        pub fn renderWorkspaceWorkObservation(
            self: *Self,
            a: std.mem.Allocator,
            value: workspace.Work,
            pending: ?occurrence.Occurrence,
            observed_at: u64,
        ) !json.Value {
            var observers =
                Observers.HistoricalObservers.init(self.allocator, value.task, observed_at);
            defer observers.deinit();
            return renderWorkspaceWorkObservationIn(self, a, value, pending, observed_at, .{
                .historical = .{ .index = &observers, .watermark = observed_at },
            });
        }
        pub fn renderWorkspaceWorkObservationIn(
            self: *Self,
            a: std.mem.Allocator,
            value: workspace.Work,
            pending: ?occurrence.Occurrence,
            observed_at: u64,
            observers: Observers.WorkObservers,
        ) !json.Value {
            const observation_blocked = try observers.blocked(self, value, observed_at);
            var result = json.object();
            try appendWorkIdentity(self, a, &result, value, pending, observed_at);
            try appendWorkRuntime(a, &result, value, observation_blocked);
            try appendWorkObserver(a, &result, value);
            try appendWorkProgress(a, &result, value, observed_at);
            try appendWorkPort(self, a, &result, value, pending, observed_at);
            try appendWorkOutcome(self, a, &result, value);
            try appendWorkInput(a, &result, value);
            try appendWorkDelivery(self, a, &result, value, pending);
            try appendWorkReferences(a, &result, value);
            try appendWorkResult(self, a, &result, value);
            return result;
        }
        fn appendWorkIdentity(
            self: *Self,
            a: std.mem.Allocator,
            result: *json.Value,
            value: workspace.Work,
            pending: ?occurrence.Occurrence,
            observed_at: u64,
        ) !void {
            try json.put(
                a,
                result,
                "interpretation_evidence",
                try workspaceInterpretationEvidence(self, a, value, pending, observed_at),
            );
            try json.put(
                a,
                result,
                "work",
                try values.toJson(wc.Ref, a, try wp.reference(a, .work, value.id)),
            );
            try json.put(
                a,
                result,
                "program",
                try values.toJson(wc.Ref, a, try wp.reference(a, .program, value.program)),
            );
            try json.put(
                a,
                result,
                "execution_revision",
                try json.number(a, value.execution_revision),
            );
            try json.put(a, result, "control_revision", try json.number(a, value.control_revision));
            try json.put(
                a,
                result,
                "realization_revision",
                try json.number(a, value.realization_revision),
            );
        }
        fn appendWorkRuntime(
            a: std.mem.Allocator,
            result: *json.Value,
            value: workspace.Work,
            observation_blocked: bool,
        ) !void {
            try json.put(
                a,
                result,
                "runtime",
                if (value.runtime) |ref| try values.toJson(
                    wc.Ref,
                    a,
                    try wp.reference(a, .runtime, ref.digest),
                ) else json.string("packaged-generic"),
            );
            try json.put(
                a,
                result,
                "available_cut",
                json.string(if (value.outer_operation != null) "outer_execution" else "guest_cut"),
            );
            try json.put(a, result, "trial", try values.toJson(?state.Digest, a, value.trial));
            try json.put(
                a,
                result,
                "outer_operation",
                try values.toJson(
                    ?state.Reference,
                    a,
                    if (value.outer_operation) |operation_value| operation_value.capsule else null,
                ),
            );
            try json.put(
                a,
                result,
                "runtime_capsule",
                try values.toJson(?state.Reference, a, value.runtime_capsule),
            );
            try json.put(
                a,
                result,
                "runtime_trace",
                try values.toJson(
                    ?kosmos.RuntimeInstrumentation.Output,
                    a,
                    if (value.runtime_trace) |trace| trace.output else null,
                ),
            );
            try json.put(a, result, "guard", try values.toJson(?workspace.Guard, a, value.guard));
            try json.put(a, result, "observation_blocked", .{ .bool = observation_blocked });
        }
        fn appendWorkObserver(
            a: std.mem.Allocator,
            result: *json.Value,
            value: workspace.Work,
        ) !void {
            if (value.observer) |observer| {
                var observed = json.object();
                try json.put(
                    a,
                    &observed,
                    "source",
                    try values.toJson(wc.GuestViewSelection, a, observer.selection.source),
                );
                try json.put(
                    a,
                    &observed,
                    "policy",
                    try values.toJson(wc.ObserverPolicy, a, observer.selection.policy),
                );
                try json.put(a, &observed, "previous", try values.toJson(
                    ?wc.Ref,
                    a,
                    observer.selection.previous,
                ));
                try json.put(a, &observed, "successor", try values.toJson(
                    ?wc.Ref,
                    a,
                    if (observer.successor) |id| try wp.reference(a, .work, id) else null,
                ));
                try json.put(
                    a,
                    &observed,
                    "consumed_revision",
                    try values.toJson(?u64, a, observer.consumed_revision),
                );
                try json.put(
                    a,
                    &observed,
                    "gap_first",
                    try values.toJson(?u64, a, observer.gap_first),
                );
                try json.put(
                    a,
                    &observed,
                    "gap_last",
                    try values.toJson(?u64, a, observer.gap_last),
                );
                try json.put(a, &observed, "stopped", .{ .bool = observer.stopped });
                try json.put(a, &observed, "incomplete", try values.toJson(
                    @TypeOf(observer.incomplete),
                    a,
                    observer.incomplete,
                ));
                try json.put(a, result, "observer", observed);
            }
        }
        fn appendWorkProgress(
            a: std.mem.Allocator,
            result: *json.Value,
            value: workspace.Work,
            observed_at: u64,
        ) !void {
            try json.put(a, result, "event_watermark", try json.number(a, observed_at));
            try json.put(a, result, "outcome", json.string(@tagName(value.outcome_kind)));
            try json.put(a, result, "schedule", json.string(@tagName(value.schedule)));
            try json.put(
                a,
                result,
                "native_publication_nanoseconds",
                try json.number(a, value.native_publication_nanoseconds),
            );
            try json.put(
                a,
                result,
                "checkpoint_publications",
                try json.number(a, value.execution_revision),
            );
            try json.put(a, result, "control_port_reachable", .{
                .bool = value.current_port != null,
            });
        }
        fn appendWorkPort(
            self: *Self,
            a: std.mem.Allocator,
            result: *json.Value,
            value: workspace.Work,
            pending: ?occurrence.Occurrence,
            observed_at: u64,
        ) !void {
            if (value.current_port) |ref| {
                const bytes = try store(self).object(a, ref, null);
                defer a.free(bytes);
                var port = try contracts.decodeOwned(workspace.Port, a, bytes);
                defer port.deinit();
                try json.put(a, result, "port", try workspacePortObservation(self, a, port.value));
                const observed = pending orelse return error.CorruptState;
                if (!std.meta.eql(observed.id, port.value.occurrence)) return error.CorruptState;
                try json.put(a, result, "port_accepts_command", .{
                    .bool = observed.state == .ready and workspaceInteractionAllowed(
                        try workspaceStoppedAt(self, a, value.task, observed_at),
                        value,
                    ),
                });
            }
        }
        fn appendWorkOutcome(
            self: *Self,
            a: std.mem.Allocator,
            result: *json.Value,
            value: workspace.Work,
        ) !void {
            const outcome_bytes = try store(self).object(a, value.outcome, null);
            defer a.free(outcome_bytes);
            var outcome = try data.invocation.decode(data.invocation.Outcome, a, outcome_bytes);
            defer outcome.deinit();
            try json.put(a, result, "cleanup_complete", .{
                .bool = cleanupComplete(outcome.value),
            });
            if (outcome.value == .failed) {
                var program = try self.workspaceProgram(a, value.task, value.program);
                defer program.deinit();
                try json.put(
                    a,
                    result,
                    "failure_preview",
                    try workspacePayloadPreview(
                        self,
                        a,
                        program.value.description.failure_schema,
                        outcome.value.failed.value,
                    ),
                );
                try json.put(
                    a,
                    result,
                    "failure",
                    try values.toJson(wc.Ref, a, try wp.reference(a, .work, value.id)),
                );
            }
        }
        fn appendWorkInput(a: std.mem.Allocator, result: *json.Value, value: workspace.Work) !void {
            try json.put(
                a,
                result,
                "input",
                try values.toJson(wc.Ref, a, try wp.reference(a, .value, (value.input_value orelse
                    return error.CorruptState).digest)),
            );
        }
        fn appendWorkDelivery(
            self: *Self,
            a: std.mem.Allocator,
            result: *json.Value,
            value: workspace.Work,
            pending: ?occurrence.Occurrence,
        ) !void {
            if (value.current_occurrence) |id| {
                const observed = pending orelse return error.CorruptState;
                if (!std.meta.eql(observed.id, id)) return error.CorruptState;
                try json.put(a, result, "delivery", json.string(@tagName(observed.state)));
                try json.put(
                    a,
                    result,
                    "occurrence",
                    json.string(try a.dupe(u8, &std.fmt.bytesToHex(id, .lower))),
                );
                if (value.trial != null) {
                    const request_bytes =
                        try store(self).object(a, observed.request_object, null);
                    defer a.free(request_bytes);
                    var request =
                        try data.invocation.decode(data.invocation.Request, a, request_bytes);
                    defer request.deinit();
                    try json.put(
                        a,
                        result,
                        "trial_proposal",
                        try @import("../dynamic_values.zig").preview(
                            a,
                            request.value.binding.payload_schema,
                            request.value.binding.payload,
                        ),
                    );
                    try json.put(
                        a,
                        result,
                        "trial_import",
                        json.string(try a.dupe(u8, request.value.binding.semantic_identity)),
                    );
                }
            }
        }
        fn appendWorkReferences(
            a: std.mem.Allocator,
            result: *json.Value,
            value: workspace.Work,
        ) !void {
            if (value.origin_work) |id| try json.put(
                a,
                result,
                "origin_work",
                try values.toJson(wc.Ref, a, try wp.reference(a, .work, id)),
            );
            if (value.answer_value) |ref| try json.put(
                a,
                result,
                "answer",
                try values.toJson(wc.Ref, a, try wp.reference(a, .value, ref.digest)),
            );
            if (value.blocker) |blocker| try json.put(
                a,
                result,
                "blocker",
                json.string(@tagName(blocker)),
            );
        }
        fn appendWorkResult(
            self: *Self,
            a: std.mem.Allocator,
            result: *json.Value,
            value: workspace.Work,
        ) !void {
            if (value.result) |ref| {
                try json.put(
                    a,
                    result,
                    "result",
                    try values.toJson(
                        wc.Ref,
                        a,
                        try wp.reference(a, .value, (value.result_value orelse
                            return error.CorruptState).digest),
                    ),
                );
                var program = try self.workspaceProgram(a, value.task, value.program);
                defer program.deinit();
                const schema =
                    try store(self).object(a, program.value.description.result_schema, null);
                defer a.free(schema);
                const bytes = try store(self).object(a, ref, null);
                defer a.free(bytes);
                try json.put(
                    a,
                    result,
                    "result_preview",
                    try @import("../dynamic_values.zig").preview(a, schema, bytes),
                );
            }
        }
        fn workspaceInterpretationEvidence(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            pending: ?occurrence.Occurrence,
            observed_at: u64,
        ) !json.Value {
            var program = try self.workspaceProgram(a, work.task, work.program);
            defer program.deinit();
            const input = work.input_value orelse return error.CorruptState;
            const bytes = try store(self).object(a, input, null);
            defer a.free(bytes);
            var artifact = try contracts.decodeOwned(workspace.ValueArtifact, a, bytes);
            defer artifact.deinit();
            var result = json.object();
            try json.put(a, &result, "evidence_class", json.string("experimental"));
            try json.put(a, &result, "analysis_checker", .null);
            try json.put(a, &result, "program", try values.toJson(
                wc.Ref,
                a,
                try wp.reference(a, .program, work.program),
            ));
            try json.put(a, &result, "executable", try values.toJson(
                state.Reference,
                a,
                program.value.description.image,
            ));
            try json.put(a, &result, "work", try values.toJson(
                wc.Ref,
                a,
                try wp.reference(a, .work, work.id),
            ));
            try json.put(a, &result, "input", try values.toJson(
                wc.Ref,
                a,
                try wp.reference(a, .value, input.digest),
            ));
            try json.put(a, &result, "input_provenance", try values.toJson(
                wc.Ref,
                a,
                try wp.reference(a, .provenance, artifact.value.provenance.digest),
            ));
            try json.put(a, &result, "result", if (work.result_value) |ref|
                try values.toJson(wc.Ref, a, try wp.reference(a, .value, ref.digest))
            else
                .null);
            try json.put(a, &result, "observed_control_trace", try workspaceInterpretationTrace(
                a,
                work,
                pending,
                observed_at,
            ));
            try appendInterpretationClaims(a, &result, work);
            return result;
        }
        fn appendInterpretationClaims(
            a: std.mem.Allocator,
            result: *json.Value,
            work: workspace.Work,
        ) !void {
            try json.put(a, result, "scope", json.string("actual_program_execution"));
            try json.put(
                a,
                result,
                "interpretation_claims",
                json.string("not_independently_checked"),
            );
            try json.put(a, result, "coverage", json.string("committed_publications_only"));
            try json.put(a, result, "reference_semantics", json.string(
                "input_provenance_does_not_certify_use",
            ));
            try json.put(
                a,
                result,
                "stopping_disposition",
                json.string(@tagName(work.outcome_kind)),
            );
        }
        fn workspaceInterpretationTrace(
            a: std.mem.Allocator,
            work: workspace.Work,
            pending: ?occurrence.Occurrence,
            observed_at: u64,
        ) !json.Value {
            return values.toJson(
                struct {
                    task: state.TaskId,
                    through_event: u64,
                    execution_revision: u64,
                    control_revision: u64,
                    checkpoint: state.Reference,
                    control: workspace.ControlObservation,
                },
                a,
                .{
                    .task = work.task,
                    .through_event = observed_at,
                    .execution_revision = work.execution_revision,
                    .control_revision = work.control_revision,
                    .checkpoint = work.checkpoint,
                    .control = workspace.ControlObservation.from(.{
                        .work = work,
                        .occurrence = pending,
                    }),
                },
            );
        }
        fn workspacePortObservation(
            self: *Self,
            a: std.mem.Allocator,
            port: workspace.Port,
        ) !json.Value {
            var result = json.object();
            try json.put(
                a,
                &result,
                "reference",
                try values.toJson(wc.Ref, a, try wp.reference(a, .port, port.id)),
            );
            try json.put(a, &result, "generation", try json.number(a, port.generation));
            try json.put(a, &result, "class", json.string(@tagName(port.interface.class)));
            try json.put(
                a,
                &result,
                "identity",
                json.string(try a.dupe(u8, port.interface.identity.bytes)),
            );
            inline for (.{ "argument", "observation", "payload", "command" }) |field| {
                const ref = @field(port.interface, field);
                const bytes = try store(self).object(a, ref, null);
                defer a.free(bytes);
                try json.put(
                    a,
                    &result,
                    field ++ "_schema",
                    try values.toJson(wc.Ref, a, try wp.reference(a, .schema, ref.digest)),
                );
                try json.put(a, &result, field ++ "_descriptor", try wp.schema(a, bytes));
            }
            const payload = try store(self).object(a, port.payload, null);
            defer a.free(payload);
            try json.put(
                a,
                &result,
                "preview",
                try workspacePayloadPreview(self, a, port.interface.payload, payload),
            );
            return result;
        }
        fn workspacePayloadPreview(
            self: *Self,
            a: std.mem.Allocator,
            schema_ref: state.Reference,
            payload: []const u8,
        ) !json.Value {
            const schema = try store(self).object(a, schema_ref, null);
            defer a.free(schema);
            return @import("../dynamic_values.zig").preview(a, schema, payload);
        }
        pub fn workspacePayloadPage(
            self: *Self,
            a: std.mem.Allocator,
            schema_ref: state.Reference,
            payload_ref: state.Reference,
            page: wc.Page,
        ) !json.Value {
            const payload = try store(self).object(a, payload_ref, null);
            defer a.free(payload);
            return workspacePayloadBytesPage(self, a, schema_ref, payload, page);
        }
        pub fn workspacePayloadBytesPage(
            self: *Self,
            a: std.mem.Allocator,
            schema_ref: state.Reference,
            payload: []const u8,
            page: wc.Page,
        ) !json.Value {
            const schema = try store(self).object(a, schema_ref, null);
            defer a.free(schema);
            return @import("../dynamic_values.zig").page(a, schema, payload, page);
        }
    };
}
