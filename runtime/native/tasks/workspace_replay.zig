const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const registry = @import("../registry.zig");
const json = @import("../json.zig");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const CompilerReadPosition = task_types.CompilerReadPosition;
const Step = task_types.Step;
const WorkspaceAdmission = task_types.WorkspaceAdmission;
const name = task_types.name;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const authorizeWorkspaceOccurrence = Access.authorizeWorkspaceOccurrence;
        const controllerAt = Controller.controllerAt;
        const controllerBinding = Controller.controllerBinding;
        const controllerEpochAt = Controller.controllerEpochAt;
        const controllerResidualIds = Recovery.controllerResidualIds;
        const controllerRuntimeAt = Realization.controllerRuntimeAt;
        const copyWorkspaceGuard = Access.copyWorkspaceGuard;
        const freezeWorkspaceWork = Access.freezeWorkspaceWork;
        const observerHeadOrder = Observers.observerHeadOrder;
        const operationKey = Records.operationKey;
        const placementReplyCopy = Transport.placementReplyCopy;
        const record = Records.record;
        const requireArchiveRecord = Occurrences.requireArchiveRecord;
        const residualPublication = Residuals.residualPublication;
        const samePublication = Access.samePublication;
        const settleWorkspaceReply = Waits.settleWorkspaceReply;
        const store = Lifecycle.store;
        const validateObservedAdvance = Observers.validateObservedAdvance;
        const validateResidualObservation = Residuals.validateResidualObservation;
        const validateWorkspaceAdmission = Admission.validateWorkspaceAdmission;
        const validateWorkspaceWorkSnapshotIn = Snapshots.validateWorkspaceWorkSnapshotIn;
        const workPublication = Access.workPublication;
        const workspaceCommandFromIn = Commands.workspaceCommandFromIn;
        const workspaceCompiles = Access.workspaceCompiles;
        const workspaceInteractionReply = Admission.workspaceInteractionReply;
        const workspaceInterruptedAt = Access.workspaceInterruptedAt;
        const workspaceIsRead = Access.workspaceIsRead;
        const workspaceRejection = Commands.workspaceRejection;
        const workspaceScopeAt = Access.workspaceScopeAt;
        const workspaceSemanticPolicy = Observations.workspaceSemanticPolicy;
        const Occurrences = @import("archive_occurrences.zig").Operations(Types, Self);
        const Residuals = @import("controller_residuals.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Transport = @import("placement_transport.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Recovery = @import("work_recovery.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Admission = @import("workspace_admission.zig").Operations(Types, Self);
        const Commands = @import("workspace_commands.zig").Operations(Types, Self);
        const Discovery = @import("reuse_discovery.zig").Operations(Types, Self);
        const ControlValidation =
            @import("workspace_control_validation.zig").Operations(Types, Self);
        const Observations = @import("workspace_observations.zig").Operations(Types, Self);
        const Observers = @import("workspace_observers.zig").Operations(Types, Self);
        const Realization = @import("workspace_realization.zig").Operations(Types, Self);
        const ResidualValidation =
            @import("workspace_residual_validation.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        const Waits = @import("workspace_waits.zig").Operations(Types, Self);
        pub fn validateWorkspacePublications(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            var root_history: state.RootHistory = .init(parent);
            var compiler_reads: std.AutoHashMap(state.Digest, CompilerReadPosition) = .init(a);
            defer compiler_reads.deinit();
            const captured_reads = try ResidualValidation.capturedControllerReads(
                self,
                a,
                parent.id,
                records,
                &compiler_reads,
            );
            defer a.free(captured_reads);
            var prefix: @import("../workspace_observers.zig").PublicationPrefix = .init(a);
            defer prefix.deinit();
            var successor_ids: std.AutoHashMap(state.Digest, state.Digest) = .init(a);
            defer successor_ids.deinit();
            var admissions: std.AutoHashMap(u64, WorkspaceAdmission) = .init(a);
            defer admissions.deinit();
            var replies: std.AutoHashMap(state.Digest, void) = .init(a);
            defer replies.deinit();
            var residuals: std.AutoHashMap(state.Digest, state.ResidualPublication) = .init(a);
            defer residuals.deinit();
            var validation: PublicationValidation = .{
                .service = self,
                .a = a,
                .parent = parent,
                .records = records,
                .checked = checked,
                .root_history = &root_history,
                .compiler_reads = &compiler_reads,
                .captured_reads = captured_reads,
                .prefix = &prefix,
                .successor_ids = &successor_ids,
                .admissions = &admissions,
                .replies = &replies,
                .residuals = &residuals,
            };
            try validation.admitReceipts();
            try validation.events();
            try validation.finalRecords();
            try validation.observerHeads();
            try validation.finish();
        }
        const PublicationValidation = publicationValidationType();
        fn publicationValidationType() type {
            return struct {
                service: *Self,
                a: std.mem.Allocator,
                parent: state.Task,
                records: []const state.ArchiveRecord,
                checked: *Snapshots.SnapshotValidation,
                root_history: *state.RootHistory,
                compiler_reads: *std.AutoHashMap(state.Digest, CompilerReadPosition),
                captured_reads: []const state.ControllerReadCut,
                captured_read: usize = 0,
                prefix: *@import("../workspace_observers.zig").PublicationPrefix,
                successor_ids: *std.AutoHashMap(state.Digest, state.Digest),
                admissions: *std.AutoHashMap(u64, WorkspaceAdmission),
                replies: *std.AutoHashMap(state.Digest, void),
                residuals: *std.AutoHashMap(state.Digest, state.ResidualPublication),
                fn admitReceipts(validation: *@This()) !void {
                    var operations = try store(validation.service).database.prepare(
                        "SELECT o.body FROM operations p JOIN objects o ON o.digest=p.rec" ++
                            "eipt WHERE p.task=?",
                        &.{.{ .blob = &validation.parent.id }},
                    );
                    defer operations.deinit();
                    while (try operations.step() == .row) {
                        var receipt_value = try contracts.decodeOwned(
                            state.Receipt,
                            validation.a,
                            try operations.bytes(0),
                        );
                        defer receipt_value.deinit();
                        const value = receipt_value.value;
                        if (value.method != .workspace) continue;
                        const entry = try validation.admissions.getOrPut(value.revision);
                        if (entry.found_existing) return error.InvalidArchive;
                        entry.value_ptr.* = .{
                            .request = value.request_digest,
                            .work = value.workspace orelse return error.InvalidArchive,
                            .kind = value.workspace_kind orelse return error.InvalidArchive,
                            .observation = value.workspace_observation,
                        };
                    }
                }
                fn events(validation: *@This()) !void {
                    var query = try store(validation.service).database.prepare(
                        "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                            "ERE e.task=? ORDER BY e.seq",
                        &.{.{ .blob = &validation.parent.id }},
                    );
                    defer query.deinit();
                    while (try query.step() == .row) {
                        var saved = try contracts.decodeOwned(
                            state.Event,
                            validation.a,
                            try query.bytes(0),
                        );
                        defer saved.deinit();
                        try validation.event(saved.value);
                    }
                }
                fn validateCommand(
                    validation: *@This(),
                    event_value: state.Event,
                    command: *?contracts.Decoded(workspace.PublicationCommand),
                    admission: anytype,
                ) !void {
                    if (event_value.kind == .workspace) {
                        const ref = event_value.workspace_command orelse
                            return error.InvalidArchive;
                        command.* = try contracts.decodeOwned(
                            workspace.PublicationCommand,
                            validation.a,
                            try store(validation.service).object(validation.a, ref, null),
                        );
                        if ((event_value.controller_read != null) != publicationReadsController(
                            command.*.?.value,
                        )) return error.InvalidArchive;
                        if (command.*.?.value == .realize_controller) {
                            const selected = command.*.?.value.realize_controller;
                            try validation.root_history.observeCut(.{
                                .controller = selected.controller,
                                .checkpoint = selected.checkpoint.digest,
                            });
                        }
                        try validateWorkspaceAdmission(
                            validation.service,
                            validation.a,
                            validation.parent,
                            event_value,
                            command.*.?.value,
                            (admission orelse return error.InvalidArchive).value,
                            validation.records,
                            validation.checked,
                        );
                        if (command.*.?.value == .context) if (event_value.controller_read) |cut|
                            try validation.checked.controller_values.put(
                                validation.checked.allocator,
                                admission.?.value.work,
                                cut,
                            );
                        if (event_value.residual_publications.items.len != @as(
                            usize,
                            if (command.*.?.value == .residual) 1 else 0,
                        )) return error.InvalidArchive;
                        if (command.*.?.value == .interact) {
                            const reply = try workspaceInteractionReply(
                                validation.service,
                                validation.a,
                                validation.parent.id,
                                command.*.?.value.interact,
                            );
                            try requireArchiveRecord(
                                validation.records,
                                .workspace_port_reply,
                                reply.id,
                            );
                            if ((try validation.replies.getOrPut(reply.id)).found_existing)
                                return error.InvalidArchive;
                        }
                    } else if (event_value.workspace_command != null or
                        (event_value.kind != .workspace_read and
                            event_value.controller_read != null))
                        return error.InvalidArchive;
                }
                fn residualEvents(
                    validation: *@This(),
                    event_value: state.Event,
                    command: ?contracts.Decoded(workspace.PublicationCommand),
                    admission: anytype,
                ) !void {
                    if (event_value.kind == .workspace_progress and
                        event_value.workspace_publications.items.len == 0 and
                        event_value.residual_publications.items.len == 0)
                        return error.InvalidArchive;
                    if (event_value.kind == .controller and
                        event_value.residual_publications.items.len != 1)
                        return error.InvalidArchive;
                    if (event_value.residual_publications.items.len > 1)
                        return error.InvalidArchive;
                    for (event_value.residual_publications.items) |item| {
                        try requireArchiveRecord(
                            validation.records,
                            .controller_residual,
                            item.value.id,
                        );
                        try ResidualValidation.validateResidualPublication(
                            validation.service,
                            validation.a,
                            validation.parent,
                            event_value,
                            item,
                            validation.residuals.get(item.value.id),
                            if (command) |decoded| decoded.value else null,
                            if (admission) |entry| entry.value else null,
                        );
                        if (event_value.kind != .controller) {
                            var parsed = try json.parseAsset(
                                validation.a,
                                event_value.data.bytes,
                                event_value.data.bytes.len,
                            );
                            defer parsed.deinit();
                            const text = try json.text(
                                parsed.value.object.get("workspace_id") orelse
                                    return error.InvalidArchive,
                            );
                            if (!std.meta.eql(
                                try wp.identity(
                                    .{
                                        .kind = .residual,
                                        .id = .{ .bytes = text },
                                    },
                                    .residual,
                                ),

                                item.value.id,
                            )) return error.InvalidArchive;
                        }
                        try validation.residuals.put(item.value.id, item);
                    }
                }
                fn readEvent(validation: *@This(), event_value: state.Event) !void {
                    if (event_value.kind == .workspace_read) {
                        var parsed = try json.parseAsset(
                            validation.a,
                            event_value.data.bytes,
                            event_value.data.bytes.len,
                        );
                        defer parsed.deinit();
                        const text = try json.text(parsed.value.object.get("occurrence_id") orelse
                            return error.InvalidArchive);
                        const id =
                            try wp.identity(.{ .kind = .work, .id = .{ .bytes = text } }, .work);
                        if (parsed.value.object.get("attempt_id")) |attempt_text| {
                            const attempt_id = try wp.identity(
                                .{
                                    .kind = .work,
                                    .id = .{ .bytes = try json.text(attempt_text) },
                                },
                                .work,
                            );
                            const read = (validation.compiler_reads.fetchRemove(attempt_id) orelse
                                return error.InvalidArchive).value;
                            if (!std.meta.eql(read.occurrence, id) or event_value.seq == 0 or
                                read.event_watermark != event_value.seq - 1 or
                                !std.meta.eql(read.controller_read, event_value.controller_read))
                                return error.InvalidArchive;
                            try requireArchiveRecord(validation.records, .occurrence, id);
                            try validation.root_history.observeCut(read.root);
                        } else {
                            try requireArchiveRecord(validation.records, .workspace_reply, id);
                            var evidence = try record(
                                validation.service,
                                workspace.ReplyObservation,
                                validation.a,
                                "workspace_reply",
                                id,
                                validation.parent.id,
                            );
                            defer evidence.deinit();
                            if (evidence.value.evidence != .read) return error.InvalidArchive;
                            const at = switch (evidence.value.evidence.read) {
                                .immutable => return error.InvalidArchive,
                                .semantic_policy => |value| value.event_watermark,
                                .reuse => |value| value.event_watermark,
                                .scope => |value| value,
                                .controller => |value| value.event_watermark,
                                .residual => |value| value.event_watermark,
                                .works => |value| value.event_watermark,
                                .wait => |value| value.event_watermark,
                            };
                            if (event_value.seq == 0 or at != event_value.seq - 1)
                                return error.InvalidArchive;
                            try validateControllerReadCut(
                                evidence.value.evidence.read,
                                event_value.controller_read,
                            );
                        }
                    }
                }
                fn workEvents(
                    validation: *@This(),
                    event_value: state.Event,
                    command: ?contracts.Decoded(workspace.PublicationCommand),
                    admission: anytype,
                ) !void {
                    if (event_value.workspace_publications.items.len != 0 and
                        event_value.kind != .workspace and event_value.kind != .workspace_progress)
                        return error.InvalidArchive;
                    if (event_value.workspace_publications.items.len != 0) {
                        var parsed = try json.parseAsset(
                            validation.a,
                            event_value.data.bytes,
                            event_value.data.bytes.len,
                        );
                        defer parsed.deinit();
                        const text = try json.text(parsed.value.object.get("workspace_id") orelse
                            return error.InvalidArchive);
                        const id =
                            try wp.identity(.{ .kind = .work, .id = .{ .bytes = text } }, .work);
                        if (!std.meta.eql(id, event_value.workspace_publications.items[0].work))
                            return error.InvalidArchive;
                    }
                    for (event_value.workspace_publications.items) |item|
                        try validation.workEvent(event_value, command, admission, item);
                }
                fn event(validation: *@This(), event_value: state.Event) !void {
                    while (validation.captured_read < validation.captured_reads.len and
                        validation.captured_reads[validation.captured_read].event_watermark <
                            event_value.seq)
                    {
                        try validation.root_history.observeRead(
                            validation.captured_reads[validation.captured_read],
                        );
                        validation.captured_read += 1;
                    }
                    try validation.root_history.observe(event_value);
                    errdefer std.debug.print("workspace publication: {s} at {d}\n", .{
                        @tagName(event_value.kind),
                        event_value.seq,
                    });
                    var command: ?contracts.Decoded(workspace.PublicationCommand) = null;
                    defer if (command) |*decoded| decoded.deinit();
                    const admission = if (event_value.kind == .workspace)
                        validation.admissions.fetchRemove(event_value.revision)
                    else
                        null;
                    try validation.validateCommand(event_value, &command, admission);
                    try validation.residualEvents(event_value, command, admission);
                    try validation.readEvent(event_value);
                    try validation.workEvents(event_value, command, admission);
                }
                fn finalRecords(validation: *@This()) !void {
                    if (validation.admissions.count() != 0 or
                        validation.compiler_reads.count() != 0)
                        return error.InvalidArchive;
                    for (validation.records) |row| {
                        if (row.kind == .workspace_port_reply and
                            !validation.replies.contains(row.id)) return error.InvalidArchive;
                        if (row.kind == .controller_residual) {
                            var residual = try record(
                                validation.service,
                                state.ControllerResidual,
                                validation.a,
                                "controller_residual",
                                row.id,
                                validation.parent.id,
                            );
                            defer residual.deinit();
                            const last =
                                validation.residuals.get(row.id) orelse return error.InvalidArchive;
                            if (!std.meta.eql(
                                last,
                                try residualPublication(
                                    validation.service,
                                    validation.a,
                                    residual.value,
                                ),
                            )) return error.InvalidArchive;
                        }
                        if (row.kind != .workspace_work) continue;
                        const current = try freezeWorkspaceWork(
                            validation.service,
                            validation.a,
                            validation.parent.id,
                            try wp.reference(validation.a, .work, row.id),
                            true,
                        );
                        const last =
                            validation.prefix.latest.get(row.id) orelse return error.InvalidArchive;
                        if (last.seq != current.work.event_watermark or !try samePublication(
                            validation.a,
                            last.publication,
                            try workPublication(validation.a, current),
                        )) return error.InvalidArchive;
                        if (current.work.observer) |observer|
                            if (!std.meta.eql(
                                observer.successor,
                                validation.successor_ids.get(row.id),
                            )) return error.InvalidArchive;
                    }
                }
                fn observerHeads(validation: *@This()) !void {
                    var active_count: usize = 0;
                    var publications = validation.prefix.latest.iterator();
                    while (publications.next()) |entry| {
                        const observer = entry.value_ptr.publication.observer orelse continue;
                        if (!observer.stopped and
                            !validation.successor_ids.contains(entry.key_ptr.*)) active_count += 1;
                    }
                    if (active_count != validation.parent.observer_heads.items.len)
                        return error.InvalidArchive;
                    for (validation.parent.observer_heads.items, 0..) |id, index| {
                        if (index != 0 and !observerHeadOrder(
                            {},
                            validation.parent.observer_heads.items[index - 1],
                            id,
                        ))
                            return error.InvalidArchive;
                        const latest =
                            validation.prefix.latest.get(id) orelse return error.InvalidArchive;
                        const observer = latest.publication.observer orelse
                            return error.InvalidArchive;
                        if (observer.stopped or validation.successor_ids.contains(id))
                            return error.InvalidArchive;
                    }
                }
                fn finish(validation: *@This()) !void {
                    for (validation.captured_reads[validation.captured_read..]) |read|
                        try validation.root_history.observeRead(read);
                    try validation.root_history.finish(validation.parent);
                }
                fn workEvent(
                    validation: *@This(),
                    event_value: state.Event,
                    command: ?contracts.Decoded(workspace.PublicationCommand),
                    admission: anytype,
                    item: state.WorkPublication,
                ) !void {
                    try requireArchiveRecord(validation.records, .workspace_work, item.work);
                    try validation.prefix.validateOuterCursor(item);
                    if (validation.prefix.latest.get(item.work)) |prior| {
                        if (prior.seq >= event_value.seq) return error.InvalidArchive;
                        inline for (.{ "execution_revision", "control_revision" }) |field| {
                            const before = @field(prior.publication, field);
                            const after = @field(item, field);
                            if (after < before or after - before > 1) return error.InvalidArchive;
                        }
                        if (validation.parent.observers_present)
                            try validateObservedAdvance(prior.publication, item, validation.prefix);
                    } else {
                        if (item.execution_revision != 1 or item.control_revision != 1)
                            return error.InvalidArchive;
                        if (item.observer) |observer| if (observer.selection.previous) |previous| {
                            const entry = try validation.successor_ids.getOrPut(
                                try wp.identity(previous, .work),
                            );
                            if (entry.found_existing) return error.InvalidArchive;
                            entry.value_ptr.* = item.work;
                        };
                    }
                    try ControlValidation.validateWorkspaceControl(
                        validation.service,
                        validation.a,
                        validation.parent,
                        event_value,
                        item,
                        if (validation.prefix.latest.get(
                            item.work,
                        )) |prior| prior.publication else null,
                        if (command) |decoded| decoded.value else null,
                        if (admission) |entry| entry.value else null,
                        validation.parent.observers_present and
                            validation.prefix.hasOuter(item.work),
                        validation.prefix,
                        &validation.checked.observer_successors.histories,
                    );
                    var retained = item;
                    if (item.observer) |observer| retained.observer =
                        try @import(
                            "../workspace_observers.zig",
                        ).copyObserver(validation.a, observer);
                    if (item.control.cancellation) |reason| retained.control.cancellation = .{
                        .bytes = try validation.a.dupe(u8, reason.bytes),
                    };
                    if (item.guard) |guard| retained.guard =
                        try copyWorkspaceGuard(validation.a, guard);
                    try validation.prefix.put(retained, event_value.seq);
                }
            };
        }
        pub fn workspaceReadBasis(
            self: *Self,
            allocator: std.mem.Allocator,
            parent: state.Task,
            command: wc.Command,
        ) ![]u8 {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var basis: workspace.ReadObservation = .immutable;
            if (command == .work and command.work == .inspect and
                command.work.inspect.work.kind == .residual)
            {
                return residualReadBasis(self, a, allocator, parent, command);
            }
            var refs: []const wc.Ref = &.{};
            var one: [1]wc.Ref = undefined;
            var retained = false;
            var collect = false;
            switch (command) {
                .work => |w| switch (w) {
                    .inspect => |r| {
                        one[0] = r.work;
                        refs = &one;
                    },
                    .collect => |r| {
                        refs = r.works.items;
                        collect = true;
                    },
                    .wait => |r| refs = r.works.items,
                    else => return error.InvalidState,
                },
                .context => |c| switch (c) {
                    .inspect => basis = .{ .scope = parent.event_high },
                    .expand => |r| if (r.reference.kind == .work) {
                        one[0] = r.reference;
                        refs = &one;
                        retained = true;
                    },
                    else => return error.InvalidState,
                },
                .program => |p| try programReadBasis(self, a, parent, p, &basis, &refs, &one),
                .placement => return error.InvalidState,
            }
            if (command == .work or refs.len != 0) {
                const observations = try a.alloc(?workspace.WorkObservation, refs.len);
                for (refs, observations) |ref, *out| out.* =
                    freezeWorkspaceWork(self, a, parent.id, ref, retained) catch |err| blk: {
                        if (!collect or err != error.ArtifactUnavailable) return err;
                        break :blk null;
                    };
                basis = if (command == .work and command.work == .wait) .{ .wait = .{
                    .works = .{ .items = observations },
                    .interrupted = parent.messages.items.len != 0 or parent.cancellation != null,
                    .event_watermark = parent.event_high,
                } } else .{ .works = .{
                    .works = .{ .items = observations },
                    .event_watermark = parent.event_high,
                } };
            }
            return contracts.encodeOwned(workspace.ReadObservation, allocator, basis);
        }
        fn residualReadBasis(
            self: *Self,
            a: std.mem.Allocator,
            allocator: std.mem.Allocator,
            parent: state.Task,
            command: wc.Command,
        ) ![]u8 {
            var residual = try record(
                self,
                state.ControllerResidual,
                a,
                "controller_residual",
                try wp.identity(command.work.inspect.work, .residual),
                parent.id,
            );
            defer residual.deinit();
            return contracts.encodeOwned(workspace.ReadObservation, allocator, .{ .residual = .{
                .value = .from(residual.value),
                .event_watermark = parent.event_high,
            } });
        }
        fn programReadBasis(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            p: wc.Program,
            basis: *workspace.ReadObservation,
            refs: *[]const wc.Ref,
            one: *[1]wc.Ref,
        ) !void {
            if (p == .build or p == .specialize or p == .adopt or
                p == .derive or p == .validate or p == .retain or p == .import)
                return error.InvalidState;
            if (p == .find or (p == .inspect and p.inspect.target == .retained)) {
                basis.* = try Discovery.capture(self, a, parent.event_high, p);
                return;
            }
            if (p == .describe and p.describe.section == .semantic_candidates)
                basis.* = .{ .semantic_policy = .{
                    .policy = try workspaceSemanticPolicy(self, a),
                    .event_watermark = parent.event_high,
                } };
            const semantic = if (p == .inspect and p.inspect.target == .semantic_source)
                p.inspect.target.semantic_source.subject
            else
                null;
            if (semantic != null and semantic.? == .work) {
                one[0] = semantic.?.work.expected.work;
                refs.* = one;
            }
            if ((p == .describe and p.describe.section == .current_controller) or
                (semantic != null and semantic.? == .controller))
            {
                basis.* = .{ .controller = .{
                    .binding = parent.controller,
                    .epoch = parent.controller_epoch,
                    .execution_revision = parent.execution_revision,
                    .runtime = parent.controller_runtime,
                    .realization_revision = parent.realization_revision,
                    .interaction = parent.controller_interaction,
                    .residuals = .{ .items = try controllerResidualIds(self, a, parent.id) },
                    .event_watermark = parent.event_high,
                } };
            }
        }
        pub fn rejectWorkspace(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            pending: occurrence.Occurrence,
            stage: @FieldType(@FieldType(workspace.ReplyEvidence, "rejected"), "stage"),
            err: anyerror,
        ) !Step {
            if (store(self).fenced or err == error.OutOfMemory or err == error.StorageUnavailable)
                return err;
            return settleWorkspaceReply(
                self,
                a,
                parent,
                pending,
                try workspaceRejection(a, err),
                .{ .rejected = .{ .stage = stage, .code = try name(@errorName(err)) } },
            );
        }
        pub fn validateHistoricalOccurrence(
            self: *Self,
            a: std.mem.Allocator,
            observed: workspace.WorkObservation,
        ) !void {
            const work = observed.work;
            if (observed.occurrence) |pending| {
                if (!std.meta.eql(work.current_occurrence, pending.id) or
                    !std.meta.eql(pending.task, work.task) or !std.meta.eql(pending.work, work.id))
                    return error.InvalidArchive;
                var current =
                    try record(self, occurrence.Occurrence, a, "occurrence", pending.id, work.task);
                defer current.deinit();
                if (!std.meta.eql(current.value.request, pending.request) or !std.meta.eql(
                    current.value.request_object,
                    pending.request_object,
                )) return error.InvalidArchive;
                // A settled observation must name the same acquired evidence;
                // later admission may change only its enclosing state tag.
                const acquired: ?occurrence.Acquired = switch (pending.state) {
                    .settled_reply => |r| r,
                    .admitted => |v| if (v == .reply) v.reply else null,
                    else => null,
                };
                if (acquired) |expected| {
                    const actual = switch (current.value.state) {
                        .settled_reply => |r| r,
                        .admitted => |v| if (v == .reply) v.reply else return error.InvalidArchive,
                        else => return error.InvalidArchive,
                    };
                    if (!std.meta.eql(expected, actual)) return error.InvalidArchive;
                }
            } else if (work.current_occurrence != null) return error.InvalidArchive;
        }
        pub fn validateControllerReadCut(
            basis: workspace.ReadObservation,
            controller_read: ?state.ControllerReadCut,
        ) !void {
            if (basis == .controller) {
                const cut = controller_read orelse return error.InvalidArchive;
                if (cut.event_watermark != basis.controller.event_watermark or
                    cut.execution_revision != basis.controller.execution_revision)
                    return error.InvalidArchive;
            } else if (controller_read != null) return error.InvalidArchive;
        }
        pub fn publicationReadsController(command: workspace.PublicationCommand) bool {
            return switch (command) {
                .realize_controller => true,
                .semantic => |selected| selected.command == .derive and
                    selected.command.derive.ancestor == .controller,
                .context => |selected| selected.command == .materialize and
                    selected.command.materialize.input == .semantic_source and
                    selected.command.materialize.input.semantic_source.subject == .controller,
                else => false,
            };
        }
        pub fn validateWorkspaceReadIn(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            command: wc.Command,
            basis: workspace.ReadObservation,
            records: []const state.ArchiveRecord,
            controller_read: ?state.ControllerReadCut,
            checked: *Snapshots.SnapshotValidation,
        ) !void {
            if (!workspaceIsRead(command)) return error.InvalidArchive;
            try validateControllerReadCut(basis, controller_read);
            if (command == .work and command.work == .inspect and
                command.work.inspect.work.kind == .residual)
            {
                try validateResidualReadBasis(self, a, parent, command, basis, records);
                return;
            }
            var refs: []const wc.Ref = &.{};
            var one: [1]wc.Ref = undefined;
            var optional = false;
            var expected: std.meta.Tag(workspace.ReadObservation) = .immutable;
            try workspaceReadSelection(command, &refs, &one, &optional, &expected);
            if (std.meta.activeTag(basis) != expected) return error.InvalidArchive;
            switch (basis) {
                .immutable => {},
                .semantic_policy => |observed| {
                    if (observed.event_watermark > parent.event_high) return error.InvalidArchive;
                },
                .reuse => |observed| {
                    if (observed.event_watermark > parent.event_high) return error.InvalidArchive;
                    try Discovery.validate(self, a, command.program, observed);
                },
                .residual => return error.InvalidArchive,
                .controller => |observed| try validateControllerReadObservation(
                    self,
                    a,
                    parent,
                    observed,
                    records,
                ),
                .scope => |watermark| {
                    if (watermark > parent.event_high) return error.InvalidArchive;
                    for (try workspaceScopeAt(
                        self,
                        a,
                        parent.id,
                        watermark,
                    )) |id| try requireArchiveRecord(records, .workspace_work, id);
                },
                .works, .wait => try validateWorksReadObservation(
                    self,
                    a,
                    parent,
                    basis,
                    records,
                    checked,
                    refs,
                    optional,
                ),
            }
        }
        fn validateResidualReadBasis(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            command: wc.Command,
            basis: workspace.ReadObservation,
            records: []const state.ArchiveRecord,
        ) !void {
            if (basis != .residual or
                basis.residual.event_watermark > parent.event_high or
                !std.meta.eql(
                    basis.residual.value.id,
                    try wp.identity(command.work.inspect.work, .residual),
                ) or !std.meta.eql(basis.residual.value.task, parent.id))
                return error.InvalidArchive;
            try requireArchiveRecord(records, .controller_residual, basis.residual.value.id);
            if (!std.meta.eql(
                basis.residual.value,
                try ResidualValidation.residualPublicationAt(
                    self,
                    a,
                    parent.id,
                    basis.residual.value.id,
                    basis.residual.event_watermark,
                ),
            )) return error.InvalidArchive;
            try validateResidualObservation(self, a, basis.residual.value);
        }
        fn validateControllerReadObservation(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            observed: @FieldType(workspace.ReadObservation, "controller"),
            records: []const state.ArchiveRecord,
        ) !void {
            if (!std.meta.eql(
                observed.binding,
                try controllerAt(self, a, parent, observed.event_watermark),
            )) return error.InvalidArchive;
            if (observed.epoch != try controllerEpochAt(
                self,
                a,
                parent,
                observed.event_watermark,
            )) return error.InvalidArchive;
            const runtime_cut =
                try controllerRuntimeAt(self, a, parent, observed.event_watermark);
            if (!std.meta.eql(runtime_cut.runtime, observed.runtime) or
                runtime_cut.realization_revision != observed.realization_revision)
                return error.InvalidArchive;
            if (observed.execution_revision > parent.execution_revision) {
                return error.InvalidArchive;
            }
            if (observed.interaction) |id| {
                try requireArchiveRecord(records, .controller_interaction, id);
                var interaction = try record(
                    self,
                    state.ControllerInteraction,
                    a,
                    "controller_interaction",
                    id,
                    parent.id,
                );
                defer interaction.deinit();
                if (!std.meta.eql(
                    observed.binding,
                    @as(?state.Digest, interaction.value.controller),
                ))
                    return error.InvalidArchive;
            }
            if (observed.binding) |id| {
                try requireArchiveRecord(records, .controller_binding, id);
                if (observed.epoch < (try controllerBinding(self, a, parent, id)).epoch)
                    return error.InvalidArchive;
            }
            try validateObservedControllerResiduals(self, a, parent, observed, records);
        }
        fn validateObservedControllerResiduals(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            observed: @FieldType(workspace.ReadObservation, "controller"),
            records: []const state.ArchiveRecord,
        ) !void {
            const all_residuals = try controllerResidualIds(self, a, parent.id);
            defer a.free(all_residuals);
            var count: usize = 0;
            for (all_residuals) |id| {
                var residual = try record(
                    self,
                    state.ControllerResidual,
                    a,
                    "controller_residual",
                    id,
                    parent.id,
                );
                defer residual.deinit();
                var operation_value = try record(
                    self,
                    state.ControllerSuccession,
                    a,
                    "controller_succession",
                    residual.value.succession,
                    parent.id,
                );
                defer operation_value.deinit();
                if ((operation_value.value.activation_event orelse
                    return error.InvalidArchive) > observed.event_watermark)
                    continue;
                if (count >= observed.residuals.items.len or
                    !std.meta.eql(observed.residuals.items[count], id)) return error.InvalidArchive;
                try requireArchiveRecord(records, .controller_residual, id);
                count += 1;
            }
            if (count != observed.residuals.items.len) return error.InvalidArchive;
        }
        fn validateWorksReadObservation(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            basis: workspace.ReadObservation,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
            refs: []const wc.Ref,
            optional: bool,
        ) !void {
            const observed =
                if (basis == .works) basis.works.works.items else basis.wait.works.items;
            const watermark =
                if (basis == .works) basis.works.event_watermark else basis.wait.event_watermark;
            if (watermark > parent.event_high) return error.InvalidArchive;
            const visible =
                if (optional) try workspaceScopeAt(self, a, parent.id, watermark) else &.{};
            if (observed.len != refs.len) return error.InvalidArchive;
            if (basis == .wait) {
                if (basis.wait.event_watermark > parent.event_high or
                    basis.wait.interrupted != try workspaceInterruptedAt(
                        self,
                        a,
                        parent.id,
                        basis.wait.event_watermark,
                    )) return error.InvalidArchive;
            }
            for (observed, refs) |item, ref| {
                const id = try wp.identity(ref, .work);
                const snapshot = item orelse {
                    if (!optional) return error.InvalidArchive;
                    for (visible) |published| if (std.meta.eql(published, id))
                        return error.InvalidArchive;
                    continue;
                };
                if (!std.meta.eql(snapshot.work.id, id) or
                    snapshot.work.event_watermark > watermark) return error.InvalidArchive;
                try requireArchiveRecord(records, .workspace_work, id);
                try validateWorkspaceWorkSnapshotIn(self, parent, snapshot, records, checked);
                if (snapshot.work.event_watermark != try ResidualValidation.workspacePublicationAt(
                    self,
                    a,
                    parent.id,
                    id,
                    watermark,
                )) return error.InvalidArchive;
                try validateHistoricalOccurrence(self, a, snapshot);
            }
        }
        fn workspaceReadSelection(
            command: wc.Command,
            refs: *[]const wc.Ref,
            one: *[1]wc.Ref,
            optional: *bool,
            expected: *std.meta.Tag(workspace.ReadObservation),
        ) !void {
            switch (command) {
                .work => |w| switch (w) {
                    .inspect => |r| {
                        one[0] = r.work;
                        refs.* = one;
                        expected.* = .works;
                    },
                    .collect => |r| {
                        refs.* = r.works.items;
                        expected.* = .works;
                        optional.* = true;
                    },
                    .wait => |r| {
                        refs.* = r.works.items;
                        expected.* = .wait;
                    },
                    else => return error.InvalidArchive,
                },
                .context => |c| switch (c) {
                    .inspect => expected.* = .scope,
                    .expand => |r| if (r.reference.kind == .work) {
                        one[0] = r.reference;
                        refs.* = one;
                        expected.* = .works;
                    },
                    else => return error.InvalidArchive,
                },
                .program => |p| {
                    if (p == .find or (p == .inspect and p.inspect.target == .retained))
                        expected.* = .reuse;
                    if (p == .describe and p.describe.section == .current_controller) {
                        expected.* = .controller;
                    }
                    if (p == .describe and p.describe.section == .semantic_candidates)
                        expected.* = .semantic_policy;
                    if (p == .inspect and p.inspect.target == .semantic_source) {
                        switch (p.inspect.target.semantic_source.subject) {
                            .runtime => {},
                            .controller => expected.* = .controller,
                            .work => |selected| {
                                one[0] = selected.expected.work;
                                refs.* = one;
                                expected.* = .works;
                            },
                        }
                    }
                },
                .placement => return error.InvalidArchive,
            }
        }
        pub fn validateWorkspaceReply(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            pending: occurrence.Occurrence,
            entry: registry.Entry,
            request: data.invocation.Request,
            saved: workspace.ReplyObservation,
            reply: []const u8,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) anyerror!void {
            try validateWorkspaceReplyIdentity(parent, pending, saved);
            const authorized_bytes = authorizeWorkspaceOccurrence(
                self,
                a,
                parent,
                pending,
                entry,
                request.binding.payload,
            ) catch |err| {
                try validateWorkspaceAuthorizationFailure(a, saved, reply, err);
                return;
            };
            var authorized = try contracts.decodeOwned(workspace.Authorized, a, authorized_bytes);
            defer authorized.deinit();
            const command = authorized.value.command;
            const operation_id = std.fmt.bytesToHex(pending.id, .lower);
            const expected: wc.Reply = switch (saved.evidence) {
                .placement => |reference| try workspaceReplyPlacement(
                    self,
                    a,
                    parent,
                    reference,
                    command,
                    &operation_id,
                    records,
                ),
                .read => |basis| try workspaceReplyRead(
                    self,
                    a,
                    parent,
                    basis,
                    authorized.value,
                    pending,
                    &operation_id,
                    records,
                    checked,
                ),
                .admitted => |admitted| try workspaceReplyAdmitted(
                    self,
                    a,
                    parent,
                    admitted,
                    authorized.value,
                    &operation_id,
                    records,
                    checked,
                ),
                .rejected => |failure| try workspaceReplyRejected(
                    self,
                    a,
                    failure,
                    command,
                    &operation_id,
                ),
            };
            if (!same(reply, try contracts.encodeOwned(wc.Reply, a, expected)))
                return error.InvalidArchive;
        }
        fn validateWorkspaceAuthorizationFailure(
            a: std.mem.Allocator,
            saved: workspace.ReplyObservation,
            reply: []const u8,
            err: anyerror,
        ) !void {
            if (saved.evidence != .rejected or saved.evidence.rejected.stage != .authorization or
                !same(saved.evidence.rejected.code.bytes, @errorName(err)))
                return error.InvalidArchive;
            const expected =
                try contracts.encodeOwned(wc.Reply, a, try workspaceRejection(a, err));
            if (!same(reply, expected)) return error.InvalidArchive;
        }
        fn validateWorkspaceReplyIdentity(
            parent: state.Task,
            pending: occurrence.Occurrence,
            saved: workspace.ReplyObservation,
        ) !void {
            if (pending.work != null or !std.meta.eql(saved.id, pending.id) or
                !std.meta.eql(saved.task, parent.id) or !std.meta.eql(
                saved.request,
                pending.request_object,
            )) return error.InvalidArchive;
            const acquired = switch (pending.state) {
                .settled_reply => |r| r,
                .admitted => |v| if (v == .reply) v.reply else return error.InvalidArchive,
                else => return error.InvalidArchive,
            };
            if (!std.meta.eql(acquired.attempt, saved.attempt)) return error.InvalidArchive;
        }
        fn workspaceReplyPlacement(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            reference: state.Reference,
            command: wc.Command,
            operation_id: []const u8,
            records: []const state.ArchiveRecord,
        ) !wc.Reply {
            const p = @import("../placement.zig");
            if (command != .placement) return error.InvalidArchive;
            const bytes = try store(self).object(a, reference, null);
            defer a.free(bytes);
            var record_value = try contracts.decodeOwned(p.ActionRecord, a, bytes);
            defer record_value.deinit();
            const action = record_value.value.action;
            try p.verify(p.Action, a, action, action.value.owner);
            const id = p.operationId(action.value.owner, parent.id, operation_id, .action);
            if (!std.meta.eql(id, record_value.value.id) or
                !std.meta.eql(id, action.value.id) or
                !std.meta.eql(parent.id, action.value.task) or
                !same(action.value.operation.bytes, operation_id)) return error.InvalidArchive;
            try requireArchiveRecord(records, .placement_action, id);
            var indexed =
                try record(self, p.ActionRecord, a, "placement_action", id, parent.id);
            defer indexed.deinit();
            if (!std.meta.eql(indexed.value.action.signature, action.signature))
                return error.InvalidArchive;
            const wanted = try contracts.encodeOwned(wc.Placement, a, command.placement);
            defer a.free(wanted);
            const actual = try contracts.encodeOwned(wc.Placement, a, action.value.request);
            defer a.free(actual);
            if (!same(wanted, actual)) return error.InvalidArchive;
            return try placementReplyCopy(a, action.value.reply);
        }
        fn workspaceReplyRead(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            basis: workspace.ReadObservation,
            authorized: workspace.Authorized,
            pending: occurrence.Occurrence,
            operation_id: []const u8,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) !wc.Reply {
            const command = authorized.command;

            const controller_read = try workspaceReplyReadCut(self, a, parent, pending, basis);
            try validateWorkspaceReadIn(
                self,
                a,
                parent,
                command,
                basis,
                records,
                controller_read,
                checked,
            );
            if (basis == .reuse) return .{
                .disposition = .observed,
                .observation_json = .{ .bytes = try json.canonical(
                    a,
                    try Discovery.historical(self, a, basis.reuse),
                ) },
            };
            return try workspaceCommandFromIn(
                self,
                a,
                operation_id,
                parent.id,
                authorized,
                basis,
                .{ .historical = &checked.observer_successors.histories },
            );
        }
        fn workspaceReplyReadCut(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            pending: occurrence.Occurrence,
            basis: workspace.ReadObservation,
        ) !?state.ControllerReadCut {
            var controller_read: ?state.ControllerReadCut = null;
            const watermark: ?u64 = switch (basis) {
                .immutable => null,
                .semantic_policy => |observed| observed.event_watermark,
                .reuse => |observed| observed.event_watermark,
                .scope => |at| at,
                .controller => |observed| observed.event_watermark,
                .residual => |observed| observed.event_watermark,
                .works => |works| works.event_watermark,
                .wait => |wait| wait.event_watermark,
            };
            if (watermark) |at| {
                // The read's own journal position anchors its prefix;
                // a forged cutoff cannot hide already-published work.
                const sequence = std.math.add(u64, at, 1) catch return error.InvalidArchive;
                var query = try store(self).database.prepare(
                    "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                        "ERE e.task=? AND e.seq=?",
                    &.{ .{ .blob = &parent.id }, .{
                        .integer = std.math.cast(i64, sequence) orelse return error.InvalidArchive,
                    } },
                );
                defer query.deinit();
                if (try query.step() != .row) return error.InvalidArchive;
                var event_value = try contracts.decodeOwned(state.Event, a, try query.bytes(0));
                defer event_value.deinit();
                if (event_value.value.kind != .workspace_read) return error.InvalidArchive;
                controller_read = event_value.value.controller_read;
                var event_data = try json.parse(a, event_value.value.data.bytes, .{});
                defer event_data.deinit();
                const id = try json.text(event_data.value.object.get("occurrence_id") orelse
                    return error.InvalidArchive);
                if (!same(id, &std.fmt.bytesToHex(pending.id, .lower))) return error.InvalidArchive;
            }
            return controller_read;
        }
        fn workspaceReplyAdmitted(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            admitted: @FieldType(workspace.ReplyEvidence, "admitted"),
            authorized: workspace.Authorized,
            operation_id: []const u8,
            records: []const state.ArchiveRecord,
            checked: *Snapshots.SnapshotValidation,
        ) !wc.Reply {
            const command = authorized.command;

            if (workspaceIsRead(command) or workspaceCompiles(command))
                return error.InvalidArchive;
            if (self.workspace_replay != null) return error.InvalidArchive;
            self.workspace_replay = .{
                .replayed = admitted.replayed,
                .records = records,
                .checked = checked,
            };
            defer self.workspace_replay = null;
            const result = try workspaceCommandFromIn(
                self,
                a,
                operation_id,
                parent.id,
                authorized,
                null,
                .{ .historical = &checked.observer_successors.histories },
            );
            if (result.disposition == .rejected) return error.InvalidArchive;
            return result;
        }
        fn workspaceReplyRejected(
            self: *Self,
            a: std.mem.Allocator,
            failure: @FieldType(workspace.ReplyEvidence, "rejected"),
            command: wc.Command,
            operation_id: []const u8,
        ) !wc.Reply {
            if (failure.stage == .authorization or failure.code.bytes.len == 0)
                return error.InvalidArchive;
            if (failure.stage == .preparation) {
                if (!workspaceCompiles(command)) return error.InvalidArchive;
            }
            const key = try operationKey(self, a, operation_id);
            if (try store(self).savedReceipt(a, &key)) |committed| {
                a.free(committed);
                return error.InvalidArchive;
            }
            // A captured operation failure is a diagnostic event. It
            // can carry no result, selected view, program or evidence.
            var observation = json.object();
            try json.put(a, &observation, "error", json.string(failure.code.bytes));
            return .{ .disposition = .rejected, .observation_json = .{
                .bytes = try json.canonical(a, observation),
            } };
        }
    };
}
