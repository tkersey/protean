const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const kosmos = @import("kosmos");
const workspace = @import("../workspace_state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const ControllerRuntimeCut = task_types.ControllerRuntimeCut;
const SelectedRuntime = task_types.SelectedRuntime;
const Work = task_types.Work;
const WorkspaceAdmission = task_types.WorkspaceAdmission;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const authorizeWorkspaceOccurrence = Access.authorizeWorkspaceOccurrence;
        const controllerAt = Controller.controllerAt;
        const controllerBinding = Controller.controllerBinding;
        const controllerEpochAt = Controller.controllerEpochAt;
        const controllerRuntime = Controller.controllerRuntime;
        const observerAdvanceAllowed = Observers.observerAdvanceAllowed;
        const observerAdvanceAllowedFor = Observers.observerAdvanceAllowedFor;
        const observerSourceRevision = Observers.observerSourceRevision;
        const occurrenceImage = Root.occurrenceImage;
        const record = Records.record;
        const replay = Records.replay;
        const requireCustody = Lifecycle.requireCustody;
        const requireSemanticPolicy = Observations.requireSemanticPolicy;
        const resident = Lifecycle.resident;
        const rootIdentity = Controller.rootIdentity;
        const rootImage = Controller.rootImage;
        const rootOperation = Controller.rootOperation;
        const rootProvenance = Controller.rootProvenance;
        const runtimeProvenance = Guards.runtimeProvenance;
        const runtimeWork = Programs.runtimeWork;
        const selectCapsuleRuntime = Snapshots.selectCapsuleRuntime;
        const snapshotRecord = Records.snapshotRecord;
        const store = Lifecycle.store;
        const validateCapsuleCheckpoint = Snapshots.validateCapsuleCheckpoint;
        const validateCapsuleOperation = Snapshots.validateCapsuleOperation;
        const validateCapsuleProvenance = Snapshots.validateCapsuleProvenance;
        const workspaceCommit = Publication.workspaceCommit;
        const workspaceParentStopped = Access.workspaceParentStopped;
        const workspaceResident = Execution.workspaceResident;
        const workspaceRuntime = Programs.workspaceRuntime;
        const writeWorkspaceWork = Publication.writeWorkspaceWork;
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Root = @import("root_execution.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Access = @import("workspace_access.zig").Operations(Types, Self);
        const Execution = @import("workspace_execution.zig").Operations(Types, Self);
        const Guards = @import("workspace_guards.zig").Operations(Types, Self);
        const Observations = @import("workspace_observations.zig").Operations(Types, Self);
        const Observers = @import("workspace_observers.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Publication = @import("workspace_publication.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        pub fn workspaceRequestCut(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            command: @FieldType(wc.Work, "request_cut"),
        ) !Admission {
            const request =
                try operation(workspace.CutRequest, a, .{
                    .task = task_id,
                    .command = command,
                });
            if (try replay(self, a, operation_id, request)) |prior| return prior;
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            if (workspaceParentStopped(self, parent.value)) return error.InvalidState;
            var work = try runtimeWork(self, a, task_id, command.expected);
            defer work.deinit();
            const driver = try workspaceResident(self, a, work.value);
            const capsule_receipt = try driver.publishCapsule(a, switch (command.level) {
                .guest_cut => .guest_cut,
                .outer_execution => .outer_execution,
            }, runtimeProvenance(work.value));
            defer capsule_receipt.deinit();
            if (parent.value.observers_present) {
                var published = work.value;
                published.runtime_capsule = .{
                    .digest = storage.digest(capsule_receipt.bytes()),
                    .bytes = capsule_receipt.bytes().len,
                };
                if (try observerSourceRevision(self, a, published, .outer_execution) !=
                    try observerSourceRevision(self, a, work.value, .outer_execution))
                    try observerAdvanceAllowedFor(self, a, work.value, .outer_execution);
            }
            const code = try driver.runtimeBytes(a);
            defer a.free(code);
            try store(self).begin();
            defer store(self).rollback();
            _ = try store(self).putObject(code);
            work.value.runtime_capsule =
                try store(self).putObject(capsule_receipt.bytes());
            work.value.runtime_dependencies = .{
                .items = try capsuleDependencies(a, capsule_receipt.bytes()),
            };
            defer a.free(work.value.runtime_dependencies.items);
            work.value.control_revision = try std.math.add(u64, work.value.control_revision, 1);
            work.value.event_watermark = parent.value.event_high + 1;
            try writeWorkspaceWork(self, &work.value, .replace);
            return workspaceCommit(
                self,
                a,
                parent.value,
                operation_id,
                request,
                work.value.id,
                .work,
                try snapshotRecord(
                    self,
                    workspace.Work,
                    a,
                    "workspace_work",
                    work.value.id,
                    task_id,
                ),
                .{ .request_cut = command },
            );
        }
        pub fn controllerRuntimeAt(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            watermark: u64,
        ) !ControllerRuntimeCut {
            var result: ControllerRuntimeCut = .{};
            var rows = try store(self).database.prepare(
                "SELECT o.body FROM events e JOIN objects o ON o.digest=e.body WH" ++
                    "ERE e.task=? AND e.seq<=? ORDER BY e.seq",
                &.{ .{ .blob = &parent.id }, .{
                    .integer = std.math.cast(i64, watermark) orelse return error.InvalidArchive,
                } },
            );
            defer rows.deinit();
            while (try rows.step() == .row) {
                var event_value = try contracts.decodeOwned(state.Event, a, try rows.bytes(0));
                defer event_value.deinit();
                if (event_value.value.kind == .controller) {
                    result = .{};
                    continue;
                }
                const reference = event_value.value.workspace_command orelse continue;
                const bytes = try store(self).object(a, reference, null);
                defer a.free(bytes);
                var command = try contracts.decodeOwned(workspace.PublicationCommand, a, bytes);
                defer command.deinit();
                if (command.value != .realize_controller) continue;
                const selected = command.value.realize_controller;
                if (selected.cut.realization_revision != result.realization_revision)
                    return error.InvalidArchive;
                result = .{
                    .runtime = selected.runtime,
                    .realization_revision = try std.math.add(u64, result.realization_revision, 1),
                };
            }
            return result;
        }
        pub fn validateControllerRealization(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            event_value: state.Event,
            selected: workspace.ControllerRealization,
            admission: WorkspaceAdmission,
        ) !void {
            if (!std.meta.eql(admission.work, rootIdentity(parent.id)) or event_value.seq == 0)
                return error.InvalidArchive;
            const cut = event_value.controller_read orelse return error.InvalidArchive;
            if (cut.event_watermark != event_value.seq - 1 or
                cut.execution_revision != selected.cut.execution_revision)
                return error.InvalidArchive;
            const receipt_body =
                try contracts.encodeOwned(workspace.ControllerRealization, a, selected);
            defer a.free(receipt_body);
            if (!std.meta.eql(admission.observation, @as(?state.Reference, .{
                .digest = storage.digest(receipt_body),
                .bytes = receipt_body.len,
            })))
                return error.InvalidArchive;
            const prior = try controllerRuntimeAt(self, a, parent, event_value.seq - 1);
            if (selected.cut.realization_revision != prior.realization_revision or
                selected.cut.epoch != try controllerEpochAt(self, a, parent, event_value.seq - 1) or
                !std.meta.eql(
                    selected.controller,
                    try controllerAt(self, a, parent, event_value.seq - 1),
                ) or
                selected.cut.execution_revision > parent.execution_revision)
                return error.InvalidArchive;
            try validateControllerRealizationExpectation(self, a, parent, selected, prior);
            if (selected.command.runtime == .selected) {
                if (selected.runtime == null or !std.meta.eql(
                    selected.runtime.?.digest,
                    try wp.identity(selected.command.runtime.selected, .runtime),
                )) return error.InvalidArchive;
            } else if (selected.runtime != null) return error.InvalidArchive;
            const guest = if (selected.controller) |id|
                (try controllerBinding(self, a, parent, id)).image
            else
                parent.image;
            if (selected.dependencies.items.len != 3 or
                !std.meta.eql(selected.dependencies.items[2], guest)) return error.InvalidArchive;
            try validateControllerRealizationCapsules(self, a, parent, selected, prior, guest);
        }
        fn validateControllerRealizationCapsules(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            selected: workspace.ControllerRealization,
            prior: ControllerRuntimeCut,
            guest: state.Reference,
        ) !void {
            const bytes = try store(self).object(a, guest, null);
            defer a.free(bytes);
            const refs = [_]?state.Reference{ prior.runtime, selected.runtime };
            const capsules = [_]state.Reference{ selected.source, selected.target };
            for (refs, capsules, selected.dependencies.items[0..2]) |ref, capsule_ref, code_ref| {
                var runtime = try controllerRuntime(self, a, parent.id, guest, ref);
                defer runtime.deinit();
                if (!std.meta.eql(runtime.identity, code_ref.digest)) return error.InvalidArchive;
                var prepared = try kosmos.Prepared.initWithRuntime(a, bytes, &runtime);
                defer prepared.deinit();
                const capsule = try store(self).object(a, capsule_ref, null);
                defer a.free(capsule);
                var envelope = try kosmos.RuntimeCapsule.read(a, capsule);
                defer envelope.deinit();
                const record_value = envelope.value.record;
                try validateControllerRealizationProvenance(
                    parent,
                    selected,
                    record_value,
                    code_ref,
                );
                const Check = struct {
                    fn claim(
                        _: *anyopaque,
                        _: kosmos.RuntimeCapsule.Reference,
                        _: kosmos.RuntimeCapsule.Record,
                        _: kosmos.RuntimeCapsule.Reference,
                    ) !void {}
                };
                var context: u8 = 0;
                var candidate = try kosmos.RuntimeCapsule.restore(
                    a,
                    &prepared.guest,
                    &runtime,
                    capsule,
                    .{ .context = &context, .claim = Check.claim },
                );
                defer candidate.deinit();
                const checkpoint = try candidate.checkpoint(a);
                defer a.free(checkpoint);
                if (!std.meta.eql(storage.digest(checkpoint), selected.checkpoint.digest) or
                    checkpoint.len != selected.checkpoint.bytes) return error.InvalidArchive;
            }
        }
        fn validateControllerRealizationProvenance(
            parent: state.Task,
            selected: workspace.ControllerRealization,
            record_value: kosmos.RuntimeCapsule.Record,
            code_ref: state.Reference,
        ) !void {
            if (record_value.operation != null or
                !std.meta.eql(record_value.provenance.execution, rootIdentity(parent.id)) or
                !std.meta.eql(record_value.provenance.custody, storage.digest(&parent.id)) or
                record_value.provenance.publication == null or
                !std.meta.eql(
                    record_value.provenance.publication.?.digest,
                    selected.checkpoint.digest,
                ) or
                record_value.provenance.publication.?.bytes != selected.checkpoint.bytes or
                !std.meta.eql(record_value.artifact.digest, code_ref.digest) or
                record_value.artifact.bytes != code_ref.bytes) return error.InvalidArchive;
        }
        fn validateControllerRealizationExpectation(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            selected: workspace.ControllerRealization,
            prior: ControllerRuntimeCut,
        ) !void {
            switch (selected.command.expected) {
                .cut => |expected| if (!std.meta.eql(expected, selected.cut))
                    return error.InvalidArchive,
                .action => |expected| {
                    if (expected.epoch != selected.cut.epoch or
                        expected.realization_revision != selected.cut.realization_revision)
                        return error.InvalidArchive;
                    var historical = parent;
                    historical.controller = selected.controller;
                    historical.controller_epoch = selected.cut.epoch;
                    historical.execution_revision = selected.cut.execution_revision;
                    historical.realization_revision = selected.cut.realization_revision;
                    historical.controller_runtime = prior.runtime;
                    historical.checkpoint = selected.checkpoint;
                    historical.current_occurrence = selected.occurrence;
                    historical.controller_interaction = try wp.identity(
                        .{
                            .kind = .controller,
                            .id = expected.interaction,
                        },
                        .controller,
                    );
                    var current = try record(
                        self,
                        occurrence.Occurrence,
                        a,
                        "occurrence",
                        selected.occurrence orelse return error.InvalidArchive,
                        parent.id,
                    );
                    defer current.deinit();
                    if (current.value.work != null or current.value.residual != null)
                        return error.InvalidArchive;
                    try validateControllerAction(
                        self,
                        a,
                        historical,
                        current.value,
                        selected.command,
                    );
                },
            }
        }
        fn controllerRealizationCut(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            parent: state.Task,
            command: @FieldType(wc.Work, "realize_controller"),
        ) !wc.ControllerCut {
            if (command.expected == .cut) return command.expected.cut;
            const expected = command.expected.action;
            const interaction_id =
                try wp.identity(.{ .kind = .controller, .id = expected.interaction }, .controller);
            if (parent.controller_interaction == null or
                !std.meta.eql(parent.controller_interaction.?, interaction_id) or
                parent.controller_epoch != expected.epoch or
                parent.realization_revision != expected.realization_revision)
                return error.StaleController;
            const id = parent.current_occurrence orelse return error.ControllerActionRequired;
            if (!same(operation_id, &std.fmt.bytesToHex(id, .lower)))
                return error.ControllerActionRequired;
            var current =
                try record(self, occurrence.Occurrence, a, "occurrence", id, parent.id);
            defer current.deinit();
            if ((current.value.state != .ready and current.value.state != .dispatching) or
                current.value.work != null or
                current.value.residual != null) return error.ControllerActionRequired;
            try validateControllerAction(self, a, parent, current.value, command);
            return .{
                .epoch = parent.controller_epoch,
                .execution_revision = parent.execution_revision,
                .realization_revision = parent.realization_revision,
            };
        }
        fn validateControllerAction(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            current: occurrence.Occurrence,
            command: @FieldType(wc.Work, "realize_controller"),
        ) !void {
            if (command.expected != .action) return error.ControllerActionRequired;
            const id = try wp.identity(
                .{
                    .kind = .controller,
                    .id = command.expected.action.interaction,
                },
                .controller,
            );
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
                parent.controller,
                @as(?state.Digest, interaction.value.controller),
            ) or
                interaction.value.epoch != command.expected.action.epoch or
                interaction.value.model == null) return error.StaleController;
            const bytes = try store(self).object(a, current.request_object, null);
            defer a.free(bytes);
            var request_value = try data.invocation.decode(data.invocation.Request, a, bytes);
            defer request_value.deinit();
            const entry = try self.handlers.resolve(
                request_value.value,
                try occurrenceImage(self, a, parent, current),
            );
            if (entry.declaration.kind != .workspace) return error.ControllerActionRequired;
            const admitted = try authorizeWorkspaceOccurrence(
                self,
                a,
                parent,
                current,
                entry,
                request_value.value.binding.payload,
            );
            defer a.free(admitted);
            var authorized = try contracts.decodeOwned(workspace.Authorized, a, admitted);
            defer authorized.deinit();
            if (authorized.value.command != .work or
                authorized.value.command.work != .realize_controller)
                return error.ControllerActionRequired;
            const actual = try contracts.encodeOwned(
                @TypeOf(command),
                a,
                authorized.value.command.work.realize_controller,
            );
            defer a.free(actual);
            const expected = try contracts.encodeOwned(@TypeOf(command), a, command);
            defer a.free(expected);
            if (!same(actual, expected)) return error.ControllerActionRequired;
        }
        pub fn workspaceRealizeController(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            command: @FieldType(wc.Work, "realize_controller"),
        ) !Admission {
            const request = try operation(workspace.ControllerRealizeRequest, a, .{
                .task = task_id,
                .command = command,
            });
            if (try replay(self, a, operation_id, request)) |prior| return prior;
            try requireCustody(self, a, task_id, null);
            var saved = try self.task(a, task_id);
            defer saved.deinit();
            const parent = saved.value;
            if (workspaceParentStopped(self, parent)) return error.InvalidState;
            if (parent.controller_succession != null) return error.ControllerHandoffPending;
            const cut = try controllerRealizationCut(self, a, operation_id, parent, command);
            if (cut.epoch != parent.controller_epoch or
                cut.execution_revision != parent.execution_revision or
                cut.realization_revision != parent.realization_revision)
                return error.StaleRevision;
            var pending = try rootOperation(self, a, parent);
            defer if (pending) |*value| value.deinit();
            if (pending != null and pending.?.value.pending != null)
                return error.GuestCutUnavailable;
            if (self.active) |active| if (active.subject == .root and
                std.meta.eql(active.task, task_id) and active.root_control != null)
                return error.GuestCutUnavailable;
            try requireControllerRealizationOccurrence(self, a, parent, operation_id);
            const image = try rootImage(self, a, parent);
            var selected: ?SelectedRuntime = if (command.runtime == .selected)
                try workspaceRuntime(
                    self,
                    a,
                    task_id,
                    try wp.identity(command.runtime.selected, .runtime),
                    null,
                )
            else
                null;
            defer if (selected) |*value| value.deinit();
            const target = if (selected) |value| value.record.value.artifact else null;
            var runtime = try controllerRuntime(self, a, task_id, image, target);
            defer runtime.deinit();
            if (target != null) try requireSemanticPolicy(
                self,
                kosmos.RuntimeCompiler.approvedRootIdentity(&runtime),
                kosmos.RuntimeCompiler.checker_identity,
            );
            return publishControllerRealization(
                self,
                a,
                parent,
                command,
                cut,
                operation_id,
                request,
                target,
                &runtime,
            );
        }
        fn publishControllerRealization(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            command: @FieldType(wc.Work, "realize_controller"),
            cut: wc.ControllerCut,
            operation_id: []const u8,
            request: state.Digest,
            target: ?state.Reference,
            runtime: *kosmos.RuntimeArtifact,
        ) !Admission {
            const driver = try resident(self, a, parent);
            const source_code = try driver.runtimeBytes(a);
            defer a.free(source_code);
            const target_code = try runtime.encode(a);
            defer a.free(target_code);
            var publisher: ControllerRealizationPublisher = .{
                .host = self,
                .a = a,
                .parent = parent,
                .command = command,
                .cut = cut,
                .operation_id = operation_id,
                .request = request,
                .runtime = target,
                .source_code = source_code,
                .target_code = target_code,
            };
            const decision = try driver.realize(
                try driver.runtimeBinding(),
                runtime,
                rootProvenance(parent),
                .{ .context = &publisher, .publish = ControllerRealizationPublisher.publish },
            );
            if (publisher.failure) |err| return err;
            if (decision != .committed) return error.PublicationUncertain;
            self.active.?.realization_revision = cut.realization_revision + 1;
            return publisher.result orelse return error.CorruptState;
        }
        fn requireControllerRealizationOccurrence(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            operation_id: []const u8,
        ) !void {
            if (parent.current_occurrence) |id| {
                var current =
                    try record(self, occurrence.Occurrence, a, "occurrence", id, parent.id);
                defer current.deinit();
                if (current.value.state == .unknown) return error.UnresolvedDelivery;
                if (current.value.state == .dispatching) {
                    if (!same(operation_id, &std.fmt.bytesToHex(id, .lower)))
                        return error.UnresolvedDelivery;
                    const bytes =
                        try store(self).object(a, current.value.request_object, null);
                    defer a.free(bytes);
                    var request_value =
                        try data.invocation.decode(data.invocation.Request, a, bytes);
                    defer request_value.deinit();
                    const entry = try self.handlers.resolve(
                        request_value.value,
                        try occurrenceImage(self, a, parent, current.value),
                    );
                    if (entry.declaration.kind != .workspace) return error.UnresolvedDelivery;
                }
                if (current.value.residual != null or current.value.work != null)
                    return error.InvalidState;
            }
        }
        const ControllerRealizationPublisher = controllerRealizationPublisherType();
        fn controllerRealizationPublisherType() type {
            return struct {
                host: *Self,
                a: std.mem.Allocator,
                parent: state.Task,
                command: @FieldType(wc.Work, "realize_controller"),
                cut: wc.ControllerCut,
                operation_id: []const u8,
                request: state.Digest,
                runtime: ?state.Reference,
                source_code: []const u8,
                target_code: []const u8,
                result: ?Admission = null,
                failure: ?anyerror = null,
                fn publish(
                    context: *anyopaque,
                    _: kosmos.RuntimeCapsule.Binding,
                    source_capsule: []const u8,
                    target_capsule: []const u8,
                ) kosmos.RuntimeCapsule.SwitchDecision {
                    const publication: *@This() = @ptrCast(@alignCast(context));
                    publication.result = publication.commit(
                        source_capsule,
                        target_capsule,
                    ) catch |err|
                        {
                            publication.failure = err;
                            return if (store(publication.host).fenced) .uncertain else .rejected;
                        };
                    return .committed;
                }
                fn commit(
                    publication: *@This(),
                    source_capsule: []const u8,
                    target_capsule: []const u8,
                ) !Admission {
                    const host = publication.host;
                    try store(host).begin();
                    defer store(host).rollback();
                    const dependencies = [_]state.Reference{
                        try store(host).putObject(publication.source_code),
                        try store(host).putObject(publication.target_code),
                        try rootImage(host, publication.a, publication.parent),
                    };
                    const fact: workspace.ControllerRealization = .{
                        .command = publication.command,
                        .cut = publication.cut,
                        .occurrence = publication.parent.current_occurrence,
                        .controller = publication.parent.controller,
                        .checkpoint = publication.parent.checkpoint,
                        .runtime = publication.runtime,
                        .source = try store(host).putObject(source_capsule),
                        .target = try store(host).putObject(target_capsule),
                        .dependencies = .{ .items = &dependencies },
                    };
                    const bytes = try contracts.encodeOwned(
                        workspace.ControllerRealization,
                        publication.a,
                        fact,
                    );
                    defer publication.a.free(bytes);
                    const observation = try store(host).putObject(bytes);
                    var next = publication.parent;
                    next.controller_runtime = publication.runtime;
                    next.realization_revision = try std.math.add(u64, next.realization_revision, 1);
                    return workspaceCommit(
                        host,
                        publication.a,
                        next,
                        publication.operation_id,
                        publication.request,
                        rootIdentity(next.id),
                        .controller,
                        observation,
                        .{ .realize_controller = fact },
                    );
                }
            };
        }
        pub fn workspaceRealize(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            command: @FieldType(wc.Work, "realize"),
        ) !Admission {
            var selected: ?SelectedRuntime =
                if (command.runtime == .selected) try workspaceRuntime(
                    self,
                    a,
                    task_id,
                    try wp.identity(command.runtime.selected, .runtime),
                    null,
                ) else null;
            defer if (selected) |*item| item.deinit();
            const target: ?state.Reference =
                if (selected) |item|
                    item.record.value.artifact
                else
                    null;
            const work_id = try wp.identity(command.expected.work, .work);
            const request = try operation(workspace.RealizeRequest, a, .{
                .task = task_id,
                .work = work_id,
                .execution = command.expected.execution_revision,
                .control = command.expected.control_revision,
                .realization = command.realization_revision,
                .runtime = target,
            });
            if (try replay(self, a, operation_id, request)) |prior| return prior;
            if (selected) |*item| try requireSemanticPolicy(
                self,
                kosmos.RuntimeCompiler.approvedRootIdentity(&item.admitted),
                kosmos.RuntimeCompiler.checker_identity,
            );
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            if (workspaceParentStopped(self, parent.value)) return error.InvalidState;
            var work = try runtimeWork(self, a, task_id, command.expected);
            defer work.deinit();
            if (work.value.guard != null) return error.GuardActive;
            if (work.value.outer_operation != null) return error.GuestCutUnavailable;
            if (work.value.realization_revision != command.realization_revision)
                return error.StaleRevision;
            try observerAdvanceAllowed(self, a, work.value);
            var program = try self.workspaceProgram(a, task_id, work.value.program);
            defer program.deinit();
            if (selected) |item| if (!std.meta.eql(item.record.value.program, work.value.program)) {
                var origin =
                    try self.workspaceProgram(a, task_id, item.record.value.program);
                defer origin.deinit();
                if (!std.meta.eql(origin.value.description.image, program.value.description.image))
                    return error.InvalidRuntime;
            };
            return realizeWorkspaceRuntime(
                self,
                a,
                parent.value,
                work.value,
                program.value,
                &selected,
                target,
                operation_id,
                request,
                command.realization_revision,
            );
        }
        fn realizeWorkspaceRuntime(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            work: workspace.Work,
            program: workspace.Program,
            selected: *?SelectedRuntime,
            target: ?state.Reference,
            operation_id: []const u8,
            request: state.Digest,
            realization_revision: u64,
        ) !Admission {
            const image = try store(self).object(a, program.description.image, null);
            defer a.free(image);
            var generic: ?kosmos.Prepared =
                if (selected.* == null) try self.program.prepare(self.allocator, image) else null;
            defer if (generic) |*item| item.deinit();
            const target_artifact = if (selected.*) |*item| &item.admitted else &generic.?.runtime;
            const driver = try workspaceResident(self, a, work);
            const source_code = try driver.runtimeBytes(a);
            defer a.free(source_code);
            const target_code = try target_artifact.encode(a);
            defer a.free(target_code);
            var publisher: WorkRealizationPublisher = .{
                .host = self,
                .a = a,
                .parent = parent,
                .work = work,
                .operation_id = operation_id,
                .request = request,
                .target = target,
                .source_code = source_code,
                .target_code = target_code,
            };
            const decision = try driver.realize(
                try driver.runtimeBinding(),
                target_artifact,
                runtimeProvenance(work),
                .{ .context = &publisher, .publish = WorkRealizationPublisher.publish },
            );
            if (publisher.failure) |err| return err;
            if (decision != .committed) return error.PublicationUncertain;
            self.active.?.realization_revision = realization_revision + 1;
            return publisher.result orelse return error.CorruptState;
        }
        const WorkRealizationPublisher = workRealizationPublisherType();
        fn workRealizationPublisherType() type {
            return struct {
                host: *Self,
                a: std.mem.Allocator,
                parent: state.Task,
                work: workspace.Work,
                operation_id: []const u8,
                request: state.Digest,
                target: ?state.Reference,
                source_code: []const u8,
                target_code: []const u8,
                result: ?Admission = null,
                failure: ?anyerror = null,
                fn publish(
                    context: *anyopaque,
                    _: kosmos.RuntimeCapsule.Binding,
                    source_capsule: []const u8,
                    target_capsule: []const u8,
                ) kosmos.RuntimeCapsule.SwitchDecision {
                    const publication: *@This() = @ptrCast(@alignCast(context));
                    publication.result = publication.commit(
                        source_capsule,
                        target_capsule,
                    ) catch |err|
                        {
                            publication.failure = err;
                            return if (store(publication.host).fenced) .uncertain else .rejected;
                        };
                    return .committed;
                }
                fn commit(
                    publication: *@This(),
                    source_capsule: []const u8,
                    target_capsule: []const u8,
                ) !Admission {
                    const host = publication.host;
                    try store(host).begin();
                    defer store(host).rollback();
                    const source_code_ref =
                        try store(host).putObject(publication.source_code);
                    const target_code_ref =
                        try store(host).putObject(publication.target_code);
                    const before = try store(host).putObject(source_capsule);
                    const after = try store(host).putObject(target_capsule);
                    var next = publication.work;
                    next.runtime = publication.target;
                    next.runtime_capsule = after;
                    next.runtime_trace = null;
                    next.runtime_dependencies = .{
                        .items = try capsuleDependencies(publication.a, target_capsule),
                    };
                    defer publication.a.free(next.runtime_dependencies.items);
                    next.realization_revision = try std.math.add(u64, next.realization_revision, 1);
                    next.control_revision = try std.math.add(u64, next.control_revision, 1);
                    next.event_watermark = publication.parent.event_high + 1;
                    try writeWorkspaceWork(host, &next, .replace);
                    const dependencies = [_]state.Reference{
                        source_code_ref,
                        target_code_ref,
                        next.runtime_dependencies.items[1],
                    };
                    return workspaceCommit(
                        host,
                        publication.a,
                        publication.parent,
                        publication.operation_id,
                        publication.request,
                        next.id,
                        .work,
                        try snapshotRecord(
                            host,
                            workspace.Work,
                            publication.a,
                            "workspace_work",
                            next.id,
                            next.task,
                        ),
                        .{
                            .realize = .{
                                .execution = publication.work.execution_revision,
                                .control = publication.work.control_revision,
                                .realization = publication.work.realization_revision,
                                .runtime = publication.target,
                                .source = before,
                                .target = after,
                                .dependencies = .{ .items = &dependencies },
                            },
                        },
                    );
                }
            };
        }
        pub fn capsuleDependencies(a: std.mem.Allocator, bytes: []const u8) ![]state.Reference {
            var decoded = try kosmos.RuntimeCapsule.read(a, bytes);
            defer decoded.deinit();
            if (decoded.value.record.dependencies.len != 2) return error.InvalidRuntime;
            const refs = try a.alloc(state.Reference, 2);
            for (refs, decoded.value.record.dependencies) |*out, ref| out.* = .{
                .digest = ref.digest,
                .bytes = ref.bytes,
            };
            return refs;
        }
        pub fn validatePublishedCapsule(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            ref: state.Reference,
            expected_runtime: ?state.Reference,
        ) !void {
            return validatePublishedCapsuleTrace(self, a, work, ref, expected_runtime, null, null);
        }
        pub fn validatePublishedCapsuleTrace(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            ref: state.Reference,
            expected_runtime: ?state.Reference,
            trace: ?kosmos.RuntimeInstrumentation.Output,
            pending_operation: ?workspace.OuterOperation,
        ) !void {
            const bytes = try store(self).object(a, ref, null);
            defer a.free(bytes);
            var envelope = try kosmos.RuntimeCapsule.read(a, bytes);
            defer envelope.deinit();
            const record_value = envelope.value.record;
            try validateCapsuleProvenance(work, record_value);
            var program = try self.workspaceProgram(a, work.task, work.program);
            defer program.deinit();
            if (!std.meta.eql(
                record_value.guest.image.digest,
                program.value.description.image.digest,
            ) or
                record_value.guest.image.bytes != program.value.description.image.bytes)
                return error.InvalidArchive;
            const image =
                try store(self).object(a, program.value.description.image, null);
            defer a.free(image);
            const runtime_ref: state.Reference = .{
                .digest = record_value.artifact.digest,
                .bytes = record_value.artifact.bytes,
            };
            const code = try store(self).object(a, runtime_ref, null);
            defer a.free(code);
            var selected =
                try selectCapsuleRuntime(self, a, work, runtime_ref, expected_runtime, image);
            defer selected.deinit();
            var prepared = try kosmos.Prepared.initWithRuntime(a, image, &selected);
            defer prepared.deinit();
            const CheckOnly = struct {
                // Private archive candidate, never installed in Service.active
                // and never given an environmental adapter or execution turn.
                fn inspect(
                    _: *anyopaque,
                    _: kosmos.RuntimeCapsule.Reference,
                    _: kosmos.RuntimeCapsule.Record,
                    _: kosmos.RuntimeCapsule.Reference,
                ) !void {}
            };
            try validateCapsuleOperation(
                self,
                a,
                work,
                ref,
                trace,
                pending_operation,
                record_value,
                envelope.value.command,
            );
            var context: u8 = 0;
            var candidate = try kosmos.RuntimeCapsule.restore(
                a,
                &prepared.guest,
                &selected,
                bytes,
                .{ .context = &context, .claim = CheckOnly.inspect },
            );
            defer candidate.deinit();
            if (pending_operation != null) return;
            try validateCapsuleCheckpoint(a, work, &candidate, &selected, trace);
        }
        pub fn validateOuterControl(
            self: *Self,
            a: std.mem.Allocator,
            work: workspace.Work,
            pending: workspace.OuterOperation,
            encoded: []const u8,
        ) !void {
            const bytes = try store(self).object(a, pending.control, null);
            defer a.free(bytes);
            var accepted = try contracts.decodeOwned(data.invocation.Control, a, bytes);
            defer accepted.deinit();
            var issued = try kosmos.RuntimeCapsule.readCommand(a, encoded);
            defer issued.deinit();
            if (issued.value != .advance or issued.value.advance.quantum != pending.guest_quantum or
                (pending.guest_quantum == 0 and accepted.value != .reply))
                return error.InvalidArchive;
            const actual = issued.value.advance.control;
            switch (accepted.value) {
                .none => if (actual != .none or work.outcome_kind != .progressed)
                    return error.InvalidArchive,
                .resume_yield => if (actual != .resume_yield or work.outcome_kind != .yielded)
                    return error.InvalidArchive,
                .cancel => |reason| {
                    const saved = work.cancellation orelse return error.InvalidArchive;
                    if (actual != .cancel or reason != .text or !same(reason.text, saved.bytes) or
                        !data.record.equal(data.invocation.Reason, reason, actual.cancel))
                        return error.InvalidArchive;
                },
                .reply => |reply| {
                    if (actual != .answer or work.outcome_kind != .requested)
                        return error.InvalidArchive;
                    var response = try data.invocation.decode(data.invocation.Result, a, reply);
                    defer response.deinit();
                    var occurrence_value = try record(
                        self,
                        occurrence.Occurrence,
                        a,
                        "occurrence",
                        work.current_occurrence orelse return error.InvalidArchive,
                        work.task,
                    );
                    defer occurrence_value.deinit();
                    const value = occurrence_value.value;
                    const acquisition = switch (value.state) {
                        .settled_reply => |acquired| acquired,
                        .admitted => |admitted| if (admitted ==
                            .reply) admitted.reply else return error.InvalidArchive,
                        else => return error.InvalidArchive,
                    };
                    if (!std.meta.eql(value.work, work.id) or
                        !std.meta.eql(value.request, response.value.request_identity) or
                        !std.meta.eql(acquisition.reply, storage.digest(reply)) or
                        !same(actual.answer, response.value.value)) return error.InvalidArchive;
                },
            }
        }
        pub fn validateRuntimeSwitch(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            item: state.WorkPublication,
            prior: state.WorkPublication,
            command: @FieldType(workspace.PublicationCommand, "realize"),
        ) !void {
            var current = try self.workspaceWork(a, task_id, item.work);
            defer current.deinit();
            var work = current.value;
            work.checkpoint = prior.checkpoint orelse return error.InvalidArchive;
            try validatePublishedCapsule(self, a, work, command.source, prior.runtime);
            try validatePublishedCapsule(self, a, work, command.target, item.runtime);
            const before_bytes = try store(self).object(a, command.source, null);
            defer a.free(before_bytes);
            const after_bytes = try store(self).object(a, command.target, null);
            defer a.free(after_bytes);
            var before = try kosmos.RuntimeCapsule.read(a, before_bytes);
            defer before.deinit();
            var after = try kosmos.RuntimeCapsule.read(a, after_bytes);
            defer after.deinit();
            const source_record = before.value.record;
            const target_record = after.value.record;
            if (source_record.kind != .guest_cut or target_record.kind != .guest_cut or
                !same(before.value.checkpoint, after.value.checkpoint) or
                !std.meta.eql(source_record.checkpoint.digest, work.checkpoint.digest) or
                source_record.checkpoint.bytes != work.checkpoint.bytes or
                source_record.guest_revision != target_record.guest_revision or
                source_record.outer_revision == std.math.maxInt(u64) or
                target_record.outer_revision != source_record.outer_revision + 1)
                return error.InvalidArchive;
            const dependencies = [_]state.Reference{
                .{ .digest = source_record.artifact.digest, .bytes = source_record.artifact.bytes },
                .{ .digest = target_record.artifact.digest, .bytes = target_record.artifact.bytes },
                .{
                    .digest = target_record.guest.image.digest,
                    .bytes = target_record.guest.image.bytes,
                },
            };
            if (command.dependencies.items.len != dependencies.len) return error.InvalidArchive;
            for (dependencies, command.dependencies.items) |wanted, actual| if (!std.meta.eql(
                wanted,
                actual,
            )) return error.InvalidArchive;
        }
    };
}
