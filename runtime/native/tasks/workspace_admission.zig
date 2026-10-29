const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const json = @import("../json.zig");
const values = @import("../values.zig");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const Work = task_types.Work;
const WorkspaceAdmission = task_types.WorkspaceAdmission;
const WorkspaceValueReference = task_types.WorkspaceValueReference;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const inspectionSelection = Inspection.inspectionSelection;
        const record = Records.record;
        const retainedWorkspaceWork = Programs.retainedWorkspaceWork;
        const store = Lifecycle.store;
        const validateControllerReadCut = replay_ops.validateControllerReadCut;
        const validateControllerRealization = Realization.validateControllerRealization;
        const validateObserver = Observers.validateObserver;
        const validateSemanticPublication = Builds.validateSemanticPublication;
        const validateSemanticReadPosition = Builds.validateSemanticReadPosition;
        const workspaceContentCustody = Programs.workspaceContentCustody;
        const workspaceOwnedDescriptor = Sources.workspaceOwnedDescriptor;
        const workspaceProgram = Programs.workspaceProgram;
        const workspaceRuntime = Programs.workspaceRuntime;
        const workspaceSnapshotAccess = Inspection.workspaceSnapshotAccess;
        const workspaceSnapshotRange = Inspection.workspaceSnapshotRange;
        const workspaceValueReference = Contexts.workspaceValueReference;
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Builds = @import("workspace_builds.zig").Operations(Types, Self);
        const Contexts = @import("workspace_contexts.zig").Operations(Types, Self);
        const Inspection = @import("workspace_inspection.zig").Operations(Types, Self);
        const Observers = @import("workspace_observers.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Realization = @import("workspace_realization.zig").Operations(Types, Self);
        const replay_ops = @import("workspace_replay.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        const Sources = @import("workspace_sources.zig").Operations(Types, Self);
        pub fn workspaceInteractionReply(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            interaction: @FieldType(wc.Work, "interact"),
        ) !workspace.PortReply {
            var port = try record(
                self,
                workspace.Port,
                a,
                "workspace_port",
                try wp.identity(interaction.port, .port),
                task_id,
            );
            defer port.deinit();
            if (!std.meta.eql(port.value.task, task_id) or
                !std.meta.eql(port.value.work, try wp.identity(interaction.expected.work, .work)) or
                port.value.generation != interaction.generation) return error.InvalidArchive;
            var pending = try record(
                self,
                occurrence.Occurrence,
                a,
                "occurrence",
                port.value.occurrence,
                task_id,
            );
            defer pending.deinit();
            const acquired = switch (pending.value.state) {
                .settled_reply => |reply| reply,
                .admitted => |admitted| if (admitted ==
                    .reply) admitted.reply else return error.InvalidArchive,
                else => return error.InvalidArchive,
            };
            var saved = try record(
                self,
                workspace.PortReply,
                a,
                "workspace_port_reply",
                acquired.attempt,
                task_id,
            );
            defer saved.deinit();
            const reply = saved.value;
            const port_bytes = try contracts.encodeOwned(workspace.Port, a, port.value);
            defer a.free(port_bytes);
            if (!std.meta.eql(reply.task, task_id) or !std.meta.eql(reply.id, acquired.attempt) or
                !std.meta.eql(reply.reply.digest, acquired.reply) or
                !std.meta.eql(reply.port, state.Reference{
                    .digest = storage.digest(port_bytes),
                    .bytes = port_bytes.len,
                })) return error.InvalidArchive;
            try validateInteractionReplyCommand(
                self,
                a,
                task_id,
                interaction,
                reply,
                port.value.interface.argument,
            );

            return reply;
        }
        fn validateInteractionReplyCommand(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            interaction: @FieldType(wc.Work, "interact"),
            reply: workspace.PortReply,
            argument: state.Reference,
        ) !void {
            switch (interaction.command) {
                .finish => if (reply.command != .finish or reply.input != null)
                    return error.InvalidArchive,
                .resume_value => |supplied| {
                    if (reply.command != .resume_value) return error.InvalidArchive;
                    const input = reply.input orelse return error.InvalidArchive;
                    const actual = try workspaceValueReference(
                        self,
                        a,
                        task_id,
                        try wp.reference(a, .value, input.digest),
                    );
                    if (!std.meta.eql(actual.artifact, input) or
                        !std.meta.eql(actual.schema, argument)) return error.InvalidArchive;
                    switch (supplied) {
                        .reference => |ref| {
                            const expected =
                                try workspaceValueReference(self, a, task_id, ref);
                            if (!std.meta.eql(expected.artifact, input))
                                return error.InvalidArchive;
                        },
                        .inline_json => |inline_value| try validateInteractionInlineReply(
                            self,
                            a,
                            inline_value,
                            actual,
                            argument,
                        ),
                    }
                },
            }
        }
        fn validateInteractionInlineReply(
            self: *Self,
            a: std.mem.Allocator,
            inline_value: @FieldType(wc.ValueInput, "inline_json"),
            actual: WorkspaceValueReference,
            argument: state.Reference,
        ) !void {
            if (!std.meta.eql(try wp.identity(inline_value.schema, .schema), argument.digest))
                return error.InvalidArchive;
            const descriptor = try store(self).object(a, argument, null);
            defer a.free(descriptor);
            const text = inline_value.json_text.bytes;
            var parsed = try json.parse(a, text, .{
                .bytes = text.len,
                .depth = text.len,
                .tokens = text.len,
                .members = text.len,
            });
            defer parsed.deinit();
            const bytes = try @import("../dynamic_values.zig").encode(a, descriptor, parsed.value);
            defer a.free(bytes);
            const provenance = try contracts.encodeOwned(
                workspace.Derivation,
                a,
                .{
                    .kind = .hypothesis,
                    .sources = .{ .items = &.{} },
                },
            );
            defer a.free(provenance);
            if (!std.meta.eql(actual.value, state.Reference{
                .digest = storage.digest(bytes),
                .bytes = bytes.len,
            }) or
                !std.meta.eql(actual.provenance, state.Reference{
                    .digest = storage.digest(provenance),
                    .bytes = provenance.len,
                })) return error.InvalidArchive;
        }
        fn validateWorkspaceContextOutput(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            context: @FieldType(workspace.PublicationCommand, "context"),
            identity: state.Digest,
            event_seq: u64,
            controller_read: ?state.ControllerReadCut,
        ) !void {
            // Replay proves receipt stability only after admission. At the archive
            // boundary, derive the content relationship from the retained command.
            return (ContextOutputValidation{
                .self = self,
                .a = a,
                .parent = parent,
                .context = context,
                .identity = identity,
                .event_seq = event_seq,
                .controller_read = controller_read,
            }).run();
        }
        const ContextOutputValidation = contextOutputValidationType();
        fn contextOutputValidationType() type {
            return struct {
                self: *Self,
                a: std.mem.Allocator,
                parent: state.Task,
                context: @FieldType(workspace.PublicationCommand, "context"),
                identity: state.Digest,
                event_seq: u64,
                controller_read: ?state.ControllerReadCut,
                fn run(ctx: @This()) !void {
                    switch (ctx.context.command) {
                        .select => |selection| try ctx.select(selection),
                        .materialize => |materialize| try ctx.materializedOutput(materialize),
                        else => return error.InvalidArchive,
                    }
                }

                fn select(ctx: @This(), selection: @FieldType(wc.Context, "select")) !void {
                    const refs = try ctx.a.alloc(state.Reference, selection.values.items.len);
                    defer ctx.a.free(refs);
                    for (selection.values.items, refs) |ref, *out|
                        out.* =
                            (try workspaceValueReference(
                                ctx.self,
                                ctx.a,
                                ctx.parent.id,
                                ref,
                            )).artifact;
                    const bytes = try contracts.encodeOwned(
                        workspace.ViewArtifact,
                        ctx.a,
                        .{ .values = .{ .items = refs } },
                    );
                    defer ctx.a.free(bytes);
                    if (!std.meta.eql(storage.digest(bytes), ctx.identity))
                        return error.InvalidArchive;
                }

                fn semanticSource(
                    ctx: @This(),
                    materialize: @FieldType(wc.Context, "materialize"),
                    selection: @FieldType(wc.Materialization, "semantic_source"),
                ) !void {
                    if (materialize.sources.items.len != 0) return error.InvalidArchive;
                    var retained = try record(
                        ctx.self,
                        workspace.Value,
                        ctx.a,
                        "workspace_value",
                        try workspaceContentCustody(ctx.a, ctx.parent.id, ctx.identity),
                        ctx.parent.id,
                    );
                    defer retained.deinit();
                    const origin = retained.value.derivation.semantic_source orelse
                        return error.InvalidArchive;
                    const requested =
                        try contracts.encodeOwned(@TypeOf(selection), ctx.a, selection);
                    defer ctx.a.free(requested);
                    const actual_selection =
                        try contracts.encodeOwned(@TypeOf(selection), ctx.a, origin.selection);
                    defer ctx.a.free(actual_selection);
                    if (!same(requested, actual_selection)) return error.InvalidArchive;
                    try validateSemanticReadPosition(origin.basis, ctx.event_seq);
                    try validateControllerReadCut(origin.basis, ctx.controller_read);
                    return;
                }

                fn guestView(
                    ctx: @This(),
                    materialize: @FieldType(wc.Context, "materialize"),
                    selection: @FieldType(wc.Materialization, "guest_view"),
                ) !void {
                    if (materialize.sources.items.len != 0) return error.InvalidArchive;
                    var retained = try record(
                        ctx.self,
                        workspace.Value,
                        ctx.a,
                        "workspace_value",
                        try workspaceContentCustody(ctx.a, ctx.parent.id, ctx.identity),
                        ctx.parent.id,
                    );
                    defer retained.deinit();
                    const origin = retained.value.derivation.inspection orelse
                        return error.InvalidArchive;
                    try inspectionSelection(origin.observation.work, selection);
                    if (origin.level != selection.level) return error.InvalidArchive;
                    if (origin.observation.work.event_watermark >= ctx.event_seq)
                        return error.InvalidArchive;
                    const requested_scope = try contracts.encodeOwned(struct {
                        nodes: wc.NodeScope,
                        values: ?wc.Disclosure,
                    }, ctx.a, .{ .nodes = selection.nodes, .values = selection.disclosure });
                    defer ctx.a.free(requested_scope);
                    const retained_scope = try contracts.encodeOwned(struct {
                        nodes: wc.NodeScope,
                        values: ?wc.Disclosure,
                    }, ctx.a, .{ .nodes = origin.nodes, .values = origin.disclosure });
                    defer ctx.a.free(retained_scope);
                    if (!same(requested_scope, retained_scope)) return error.InvalidArchive;
                    // Value access already reconstructs the exact bytes
                    // from the journal-bound observation and scope.
                    return;
                }

                fn inlineValue(
                    ctx: @This(),
                    inline_value: @FieldType(wc.ValueInput, "inline_json"),
                    schema: *state.Reference,
                    payload: *state.Reference,
                ) !void {
                    schema.* = try workspaceOwnedDescriptor(
                        ctx.self,
                        ctx.a,
                        ctx.parent.id,
                        inline_value.schema,
                    );
                    const descriptor = try store(ctx.self).object(ctx.a, schema.*, null);
                    defer ctx.a.free(descriptor);
                    const text = inline_value.json_text.bytes;
                    var parsed = try json.parse(ctx.a, text, .{
                        .bytes = text.len,
                        .depth = text.len,
                        .tokens = text.len,
                        .members = text.len,
                    });
                    defer parsed.deinit();
                    const bytes = try @import("../dynamic_values.zig").encode(
                        ctx.a,
                        descriptor,
                        parsed.value,
                    );
                    defer ctx.a.free(bytes);
                    payload.* = .{ .digest = storage.digest(bytes), .bytes = bytes.len };
                }

                fn value(
                    ctx: @This(),
                    materialize: @FieldType(wc.Context, "materialize"),
                    input: wc.ValueInput,
                    actual: WorkspaceValueReference,
                    schema: *state.Reference,
                    payload: *state.Reference,
                    derivation: *workspace.Derivation,
                    sources: *std.ArrayList(state.Reference),
                ) !bool {
                    for (materialize.sources.items) |ref| try sources.append(
                        ctx.a,
                        (try workspaceValueReference(ctx.self, ctx.a, ctx.parent.id, ref)).artifact,
                    );
                    switch (input) {
                        .reference => |ref| {
                            const origin =
                                try workspaceValueReference(ctx.self, ctx.a, ctx.parent.id, ref);
                            if (sources.items.len == 0) {
                                if (!std.meta.eql(origin.artifact, actual.artifact))
                                    return error.InvalidArchive;
                                return false;
                            }
                            try sources.append(ctx.a, origin.artifact);
                            schema.* = origin.schema;
                            payload.* = origin.value;
                        },
                        .inline_json => |inline_value| try ctx.inlineValue(
                            inline_value,
                            schema,
                            payload,
                        ),
                    }
                    derivation.* = .{
                        .kind = if (sources.items.len == 0) .hypothesis else .judgment,
                        .sources = .{ .items = sources.items },
                    };

                    return true;
                }

                fn materializedOutput(
                    ctx: @This(),
                    materialize: @FieldType(wc.Context, "materialize"),
                ) !void {
                    const actual = try workspaceValueReference(
                        ctx.self,
                        ctx.a,
                        ctx.parent.id,
                        try wp.reference(ctx.a, .value, ctx.identity),
                    );
                    var schema = actual.schema;
                    var payload = actual.value;
                    var derivation: workspace.Derivation = .{
                        .kind = .hypothesis,
                        .sources = .{ .items = &.{} },
                    };
                    var sources: std.ArrayList(state.Reference) = .empty;
                    defer sources.deinit(ctx.a);
                    switch (materialize.input) {
                        .semantic_source => |selection| return ctx.semanticSource(
                            materialize,
                            selection,
                        ),
                        .guest_view => |selection| return ctx.guestView(materialize, selection),
                        .authorized_input => {
                            if (materialize.sources.items.len != 0) return error.InvalidArchive;
                            const ref = ctx.context.input orelse return error.InvalidArchive;
                            try workspaceSnapshotAccess(ctx.parent, ref);
                            derivation = .{
                                .kind = .acquisition,
                                .sources = .{ .items = &.{} },
                                .frozen_input = ref,
                            };
                            // workspaceValueReference checks the actual schema
                            // and payload against this exact frozen input.
                        },
                        .snapshot => |selection| {
                            if (materialize.sources.items.len != 0) return error.InvalidArchive;
                            derivation = .{
                                .kind = .acquisition,
                                .sources = .{ .items = &.{} },
                                .acquisition = try workspaceSnapshotRange(
                                    ctx.self,
                                    ctx.a,
                                    ctx.parent,
                                    ctx.context.snapshot orelse return error.InvalidArchive,
                                    selection,
                                ),
                            };
                        },
                        .value => |input| if (!try ctx.value(
                            materialize,
                            input,
                            actual,
                            &schema,
                            &payload,
                            &derivation,
                            &sources,
                        )) return,
                    }
                    try ctx.materializedProvenance(actual, schema, payload, derivation);
                }
                fn materializedProvenance(
                    ctx: @This(),
                    actual: WorkspaceValueReference,
                    schema: state.Reference,
                    payload: state.Reference,
                    derivation: workspace.Derivation,
                ) !void {
                    const provenance =
                        try contracts.encodeOwned(workspace.Derivation, ctx.a, derivation);
                    defer ctx.a.free(provenance);
                    if (!std.meta.eql(actual.schema, schema) or
                        !std.meta.eql(actual.value, payload) or
                        !std.meta.eql(actual.provenance, state.Reference{
                            .digest = storage.digest(provenance),
                            .bytes = provenance.len,
                        })) return error.InvalidArchive;
                }
            };
        }
        pub fn validateWorkspaceAdmission(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            event_value: state.Event,
            command: workspace.PublicationCommand,
            admission: WorkspaceAdmission,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            // Validate the receipt's operation before interpreting any declared
            // publication. Neither the receipt kind nor an empty list can bypass it.
            return (PublicationAdmissionValidation{
                .self = self,
                .a = a,
                .parent = parent,
                .event_value = event_value,
                .command = command,
                .admission = admission,
                .records = records,
                .checked = checked,
            }).run();
        }
        const PublicationAdmissionValidation = publicationAdmissionValidationType();
        fn publicationAdmissionValidationType() type {
            return struct {
                self: *Self,
                a: std.mem.Allocator,
                parent: state.Task,
                event_value: state.Event,
                command: workspace.PublicationCommand,
                admission: WorkspaceAdmission,
                records: []const state.ArchiveRecord,
                checked: *Snapshots.SnapshotValidation,
                fn run(ctx: @This()) !void {
                    errdefer std.debug.print("workspace admission: {s} at {d}\n", .{
                        @tagName(ctx.command),
                        ctx.event_value.seq,
                    });
                    try ctx.publicationShape();
                    const request = switch (ctx.command) {
                        .realize_controller => |selection| try ctx.requestRealizeController(
                            selection,
                        ),
                        .stop_observing => |selection| try ctx.requestStopObserving(selection),
                        .semantic => |selected| try ctx.requestSemantic(selected),
                        .residual => |selection| try ctx.requestResidual(selection),
                        .specialize => |selection| try ctx.requestSpecialize(selection),
                        .realize => |selection| try ctx.requestRealize(selection),
                        .pump => |selection| try ctx.requestPump(selection),
                        .guard => |selection| try ctx.requestGuard(selection),
                        .unguard => |selection| try ctx.requestUnguard(selection),
                        .request_cut => |selection| try ctx.requestRequestCut(selection),
                        .build => try ctx.requestBuild(),
                        .context => |context| try ctx.requestContext(context),
                        .start => |start| try ctx.requestStart(start),
                        .control => |control| try ctx.requestControl(control),
                        .interact => |interaction| try ctx.requestInteract(interaction),
                        .delegate => |selection| try ctx.requestDelegate(selection),
                    };
                    if (!std.meta.eql(request, ctx.admission.request)) return error.InvalidArchive;
                }

                fn publicationShape(ctx: @This()) !void {
                    const items = ctx.event_value.workspace_publications.items;
                    const kind: @FieldType(wc.Ref, "kind") = switch (ctx.command) {
                        .build => .program,
                        .realize_controller => .controller,
                        .residual => .residual,
                        .specialize => .runtime,
                        .semantic => .candidate,
                        .context => |context| switch (context.command) {
                            .materialize => .value,
                            .select => .view,
                            else => return error.InvalidArchive,
                        },
                        else => .work,
                    };
                    if (ctx.admission.kind != kind) return error.InvalidArchive;
                    const count: usize = switch (ctx.command) {
                        .build,
                        .context,
                        .specialize,
                        .semantic,
                        .residual,
                        .realize_controller,
                        => 0,
                        .delegate => 2,
                        .start => |start| if (start.observer) |observer|
                            if (observer.selection.previous != null) 2 else 1
                        else
                            1,
                        else => 1,
                    };
                    if (items.len != count) return error.InvalidArchive;
                    if (count != 0 and !std.meta.eql(items[0].work, ctx.admission.work))
                        return error.InvalidArchive;
                }

                fn requestRealizeController(
                    ctx: @This(),
                    selection: @FieldType(workspace.PublicationCommand, "realize_controller"),
                ) !state.Digest {
                    try validateControllerRealization(
                        ctx.self,
                        ctx.a,
                        ctx.parent,
                        ctx.event_value,
                        selection,
                        ctx.admission,
                    );
                    return try operation(workspace.ControllerRealizeRequest, ctx.a, .{
                        .task = ctx.parent.id,
                        .command = selection.command,
                    });
                }

                fn requestStopObserving(
                    ctx: @This(),
                    selection: @FieldType(workspace.PublicationCommand, "stop_observing"),
                ) !state.Digest {
                    return try operation(workspace.StopObservingRequest, ctx.a, .{
                        .task = ctx.parent.id,
                        .expected = selection,
                    });
                }

                fn requestSemantic(
                    ctx: @This(),
                    selected: @FieldType(workspace.PublicationCommand, "semantic"),
                ) !state.Digest {
                    try validateSemanticPublication(
                        ctx.self,
                        ctx.parent,
                        selected,
                        ctx.admission,
                        ctx.records,
                        ctx.event_value.seq,
                        ctx.event_value.controller_read,
                        ctx.checked,
                    );
                    return try operation(workspace.SemanticRequest, ctx.a, .{
                        .task = ctx.parent.id,
                        .command = selected.command,
                    });
                }

                fn requestResidual(
                    ctx: @This(),
                    selection: @FieldType(workspace.PublicationCommand, "residual"),
                ) !state.Digest {
                    return try operation(workspace.ResidualControlRequest, ctx.a, .{
                        .task = ctx.parent.id,
                        .residual = ctx.admission.work,
                        .execution = selection.execution,
                        .control = selection.control,
                        .command = selection.command,
                    });
                }

                fn requestSpecialize(
                    ctx: @This(),
                    selection: @FieldType(workspace.PublicationCommand, "specialize"),
                ) !state.Digest {
                    var selected = try workspaceRuntime(
                        ctx.self,
                        ctx.a,
                        ctx.parent.id,
                        ctx.admission.work,
                        selection.program,
                    );
                    defer selected.deinit();
                    const hooks = selected.admitted.content.value.hooks;
                    if (hooks.control != selection.hooks.control or
                        hooks.storage != selection.hooks.storage)
                        return error.InvalidArchive;
                    return try operation(workspace.SpecializeRequest, ctx.a, .{
                        .task = ctx.parent.id,
                        .program = selection.program,
                        .hooks = selection.hooks,
                    });
                }

                fn requestRealize(
                    ctx: @This(),
                    selection: @FieldType(workspace.PublicationCommand, "realize"),
                ) !state.Digest {
                    return try operation(workspace.RealizeRequest, ctx.a, .{
                        .task = ctx.parent.id,
                        .work = ctx.admission.work,
                        .execution = selection.execution,
                        .control = selection.control,
                        .realization = selection.realization,
                        .runtime = selection.runtime,
                    });
                }

                fn requestPump(
                    ctx: @This(),
                    selection: @FieldType(workspace.PublicationCommand, "pump"),
                ) !state.Digest {
                    if (!std.meta.eql(
                        try wp.identity(selection.expected.work, .work),
                        ctx.admission.work,
                    )) return error.InvalidArchive;
                    return try operation(workspace.PumpRequest, ctx.a, .{
                        .task = ctx.parent.id,
                        .command = selection,
                    });
                }

                fn requestGuard(
                    ctx: @This(),
                    selection: @FieldType(workspace.PublicationCommand, "guard"),
                ) !state.Digest {
                    return try operation(workspace.GuardRequest, ctx.a, .{
                        .task = ctx.parent.id,
                        .command = .{ .guard = selection },
                    });
                }

                fn requestUnguard(
                    ctx: @This(),
                    selection: @FieldType(workspace.PublicationCommand, "unguard"),
                ) !state.Digest {
                    return try operation(workspace.GuardRequest, ctx.a, .{
                        .task = ctx.parent.id,
                        .command = .{ .unguard = selection },
                    });
                }

                fn requestRequestCut(
                    ctx: @This(),
                    selection: @FieldType(workspace.PublicationCommand, "request_cut"),
                ) !state.Digest {
                    if (!std.meta.eql(
                        try wp.identity(selection.expected.work, .work),
                        ctx.admission.work,
                    )) return error.InvalidArchive;
                    return try operation(workspace.CutRequest, ctx.a, .{
                        .task = ctx.parent.id,
                        .command = selection,
                    });
                }

                fn requestBuild(ctx: @This()) !state.Digest {
                    var program =
                        try workspaceProgram(ctx.self, ctx.a, ctx.parent.id, ctx.admission.work);
                    defer program.deinit();
                    const artifact = program.value.description;
                    if (artifact.source_kind != .source_records and
                        artifact.source_kind != .component_recipe and
                        artifact.source_kind != .source_derivation)
                        return error.InvalidArchive;
                    return try operation(workspace.BuildRequest, ctx.a, .{
                        .task = ctx.parent.id,
                        .source = .{
                            .bytes = try store(ctx.self).object(ctx.a, artifact.source, null),
                        },
                        .source_kind = @fromBackingInt(@intCast(@backingInt(artifact.source_kind))),
                        .catalog = artifact.catalog,
                        .exposures = artifact.exposures,
                        .role = if (artifact.controller != null) .controller else .computation,
                    });
                }

                fn requestContext(
                    ctx: @This(),
                    context: @FieldType(workspace.PublicationCommand, "context"),
                ) !state.Digest {
                    try validateWorkspaceContextOutput(
                        ctx.self,
                        ctx.a,
                        ctx.parent,
                        context,
                        ctx.admission.work,
                        ctx.event_value.seq,
                        ctx.event_value.controller_read,
                    );
                    return try operation(workspace.ContextRequest, ctx.a, .{
                        .task = ctx.parent.id,
                        .command = context.command,
                        .snapshot = context.snapshot,
                        .input = context.input,
                    });
                }

                fn requestStart(
                    ctx: @This(),
                    start: @FieldType(workspace.PublicationCommand, "start"),
                ) !state.Digest {
                    if (ctx.event_value.workspace_publications.items.len == 2) {
                        const previous = start.observer.?.selection.previous.?;
                        if (!std.meta.eql(
                            ctx.event_value.workspace_publications.items[1].work,
                            try wp.identity(previous, .work),
                        ) or
                            std.meta.eql(
                                ctx.event_value.workspace_publications.items[0].work,
                                ctx.event_value.workspace_publications.items[1].work,
                            )) return error.InvalidArchive;
                    }
                    var work = try retainedWorkspaceWork(
                        ctx.self,
                        ctx.a,
                        ctx.parent.id,
                        ctx.admission.work,
                    );
                    defer work.deinit();
                    if ((start.trial == .none) != (work.value.trial == null))
                        return error.InvalidArchive;
                    if (work.value.trial) |id| try ctx.validateTrial(start.trial, id);

                    if (!start.origin) try validateWorkspaceInitialInput(
                        ctx.self,
                        ctx.a,
                        work.value,
                        &ctx.checked.observer_successors,
                    );
                    if (start.observer) |observer| return try operation(
                        workspace.ObserveRequest,
                        ctx.a,
                        .{ .task = ctx.parent.id, .selection = observer.selection },
                    );
                    return try operation(workspace.StartRequest, ctx.a, .{
                        .task = ctx.parent.id,
                        .program = work.value.program,
                        .input = .{
                            .bytes = try store(ctx.self).object(ctx.a, work.value.input, null),
                        },
                        .policy = start.policy,
                        .origin = if (start.origin) work.value.input_value else null,
                        .runtime = start.runtime,
                        .trial = start.trial,
                    });
                }

                fn validateTrial(ctx: @This(), selection: wc.Trial, id: state.Digest) !void {
                    var trial = try record(
                        ctx.self,
                        workspace.Trial,
                        ctx.a,
                        "workspace_trial",
                        id,
                        ctx.parent.id,
                    );
                    defer trial.deinit();
                    const selected = try contracts.encodeOwned(wc.Trial, ctx.a, selection);
                    defer ctx.a.free(selected);
                    const retained =
                        try contracts.encodeOwned(wc.Trial, ctx.a, trial.value.selection);
                    defer ctx.a.free(retained);
                    if (!same(selected, retained)) return error.InvalidArchive;
                    var view = try contracts.decodeOwned(
                        contracts.controller.OwnerView,
                        ctx.a,
                        try store(ctx.self).object(ctx.a, trial.value.view, null),
                    );
                    defer view.deinit();
                    if (ctx.event_value.seq == 0 or view.value.event_cut != ctx.event_value.seq - 1)
                        return error.InvalidArchive;
                }
                fn requestControl(
                    ctx: @This(),
                    control: @FieldType(workspace.PublicationCommand, "control"),
                ) !state.Digest {
                    return try operation(workspace.ControlRequest, ctx.a, .{
                        .task = ctx.parent.id,
                        .work = ctx.admission.work,
                        .execution = control.execution,
                        .control = control.control,
                        .command = control.command,
                    });
                }

                fn requestInteract(
                    ctx: @This(),
                    interaction: @FieldType(workspace.PublicationCommand, "interact"),
                ) !state.Digest {
                    return try operation(workspace.InteractionRequest, ctx.a, .{
                        .task = ctx.parent.id,
                        .interaction = interaction,
                    });
                }

                fn requestDelegate(
                    ctx: @This(),
                    selection: @FieldType(workspace.PublicationCommand, "delegate"),
                ) !state.Digest {
                    const target = try wp.identity(selection.expected.work, .work);
                    if (!std.meta.eql(
                        ctx.event_value.workspace_publications.items[1].work,
                        target,
                    ) or
                        std.meta.eql(ctx.event_value.workspace_publications.items[0].work, target))
                        return error.InvalidArchive;
                    var child = try retainedWorkspaceWork(
                        ctx.self,
                        ctx.a,
                        ctx.parent.id,
                        ctx.admission.work,
                    );
                    defer child.deinit();
                    try validateWorkspaceInitialInput(
                        ctx.self,
                        ctx.a,
                        child.value,
                        &ctx.checked.observer_successors,
                    );
                    return try operation(workspace.DelegationRequest, ctx.a, .{
                        .task = ctx.parent.id,
                        .command = selection,
                    });
                }
            };
        }
        fn validateWorkspaceInitialInput(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            successors: *Observers.ObserverSuccessors,
        ) !void {
            // An originless admission derives this identity from the constructor;
            // equal schema/payload bytes do not authorize different ancestry.
            try validateObserver(self, a, work, successors);
            const ref = work.input_value orelse return error.InvalidArchive;
            const input = try workspaceValueReference(
                self,
                a,
                work.task,
                try wp.reference(a, .value, ref.digest),
            );
            const inputs = if (work.observer) |observer|
                &[_]state.Reference{ observer.source, observer.accumulator }
            else
                &.{};
            const provenance = try contracts.encodeOwned(workspace.Derivation, a, .{
                .kind = if (work.observer != null) .judgment else .hypothesis,
                .sources = .{ .items = inputs },
            });
            defer a.free(provenance);
            if (!std.meta.eql(input.provenance, state.Reference{
                .digest = storage.digest(provenance),
                .bytes = provenance.len,
            })) return error.InvalidArchive;
        }
    };
}
