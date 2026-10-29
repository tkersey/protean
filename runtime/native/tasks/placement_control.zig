const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const Work = task_types.Work;
const cleanupComplete = task_types.cleanupComplete;
const operation = task_types.operation;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const activeObserver = Observers.activeObserver;
        const claim = Scheduling.claim;
        const ensureOwnershipCapacity = Scheduling.ensureOwnershipCapacity;
        const hasLocalCustody = Lifecycle.hasLocalCustody;
        const placementAuthorizeMessage = Transport.placementAuthorizeMessage;
        const placementPeer = Transport.placementPeer;
        const placementPeerAt = Transport.placementPeerAt;
        const placementPutControl = Transport.placementPutControl;
        const placementQueue = Transport.placementQueue;
        const placementSite = Lifecycle.placementSite;
        const record = Records.record;
        const requireCustody = Lifecycle.requireCustody;
        const store = Lifecycle.store;
        const subjectAddAssumeCapacity = Scheduling.subjectAddAssumeCapacity;
        const workspaceExplicitlyParked = Recovery.workspaceExplicitlyParked;
        const workspaceWorkSettled = Tasks.workspaceWorkSettled;
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Transport = @import("placement_transport.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Recovery = @import("work_recovery.zig").Operations(Types, Self);
        const Commands = @import("workspace_commands.zig").Operations(Types, Self);
        const Observers = @import("workspace_observers.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        pub fn placementStatus(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("../placement.zig").Subject,
        ) !?@import("../placement.zig").Custody {
            var parent = try self.task(a, subject.task);
            defer parent.deinit();
            var saved = try @import("../placement_journal.zig").custody(
                store(self),
                a,
                subject,
            ) orelse return null;
            defer saved.deinit();
            return saved.value;
        }
        pub fn placementControl(
            self: *Self,
            a: std.mem.Allocator,
            operation_name: []const u8,
            task_id: state.TaskId,
            command: wc.Work,
        ) ![]u8 {
            // Persist before transport. An unanswered command prevents controller
            // succession, so a delayed command cannot cross an ownership epoch.
            return placementControlExpanded(
                self,
                a,
                operation_name,
                task_id,
                command,
                null,
                false,
                null,
            );
        }
        pub fn placementControlExpanded(
            self: *Self,
            a: std.mem.Allocator,
            operation_name: []const u8,
            task_id: state.TaskId,
            command: wc.Work,
            expansion: @FieldType(@import("../placement.zig").Control, "expansion"),
            require_transport: bool,
            cleanup_request: ?u64,
        ) ![]u8 {
            const p = @import("../placement.zig");
            const journal = @import("../placement_journal.zig");
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            const site = try placementSite(self);
            const work_id = try wp.identity(try p.commandWork(command), .work);
            var controller = try journal.custody(store(self), a, .{
                .task = task_id,
            }) orelse return error.InvalidTransfer;
            defer controller.deinit();
            try controller.value.requireLocal(site);
            var executor = try journal.custody(store(self), a, .{
                .task = task_id,
                .work = work_id,
            }) orelse return error.InvalidTransfer;
            defer executor.deinit();
            if (executor.value.phase != .away or std.meta.eql(executor.value.owner, site))
                return error.CustodyNotRemote;
            if (operation_name.len == 0 or operation_name.len > 128) return error.InvalidOperation;
            const value: p.Control = .{
                .subject = .{ .task = task_id, .work = work_id },
                .controller = site,
                .controller_epoch = controller.value.epoch,
                .executor = executor.value.owner,
                .custody_epoch = executor.value.epoch,
                .operation = .{ .bytes = operation_name },
                .command = command,
                .expansion = expansion,
                .cleanup_request = cleanup_request,
                .parent_stopped = parent.value.terminal() or parent.value.cancellation != null,
            };
            const id = p.controlId(value);
            if (try journal.control(store(self), a, task_id, id)) |saved| {
                return placementReplayControl(self, a, value, saved);
            }
            if (require_transport and (try placementPeerAt(
                self,
                value.executor,
            )).channel == null) return error.UnsupportedCapability;
            const signed = try p.sign(p.Control, a, self.profile.placement.?.signing_key, value);
            const result = try contracts.encodeOwned(p.Signed(p.Control), a, signed);
            errdefer a.free(result);
            try placementPutControl(
                self,
                a,
                try placementPeerAt(self, value.executor),
                .{ .id = id, .task = task_id, .control = signed },
                result,
                "placement.control",
            );
            return result;
        }
        fn placementReplayControl(
            self: *Self,
            a: std.mem.Allocator,
            value: @import("../placement.zig").Control,
            saved: contracts.Decoded(@import("../placement.zig").ControlRecord),
        ) ![]u8 {
            const p = @import("../placement.zig");
            var prior = saved;
            defer prior.deinit();
            var replay_value = value;
            replay_value.executor = prior.value.control.value.executor;
            replay_value.custody_epoch = prior.value.control.value.custody_epoch;
            replay_value.parent_stopped = prior.value.control.value.parent_stopped;
            if (replay_value.cleanup_request == null) replay_value.cleanup_request =
                prior.value.control.value.cleanup_request;
            if (!std.meta.eql(
                try p.digest(p.Control, a, prior.value.control.value),
                try p.digest(p.Control, a, replay_value),
            )) return error.OperationConflict;
            const bytes = try contracts.encodeOwned(p.Signed(p.Control), a, prior.value.control);
            errdefer a.free(bytes);
            const head = try p.routeHead(a, prior.value.control.value, prior.value.route.items);
            try placementAuthorizeMessage(
                self,
                a,
                try placementPeerAt(self, head.site),
                value.subject,
                bytes,
            );
            return bytes;
        }
        pub fn placementExecuteControl(
            self: *Self,
            a: std.mem.Allocator,
            peer_name: []const u8,
            signed: @import("../placement.zig").Signed(@import("../placement.zig").Control),
        ) ![]u8 {
            return placementExecuteRoutedControl(self, a, peer_name, signed, &.{});
        }
        pub fn placementResolveControl(
            self: *Self,
            a: std.mem.Allocator,
            peer_name: []const u8,
            signed: @import("../placement.zig").Signed(@import("../placement.zig").Control),
            route: []const @import("../placement.zig").Succession,
        ) ![]u8 {
            const p = @import("../placement.zig");
            const journal = @import("../placement_journal.zig");
            var parent = try self.task(a, signed.value.subject.task);
            defer parent.deinit();
            const peer = try placementPeer(self, peer_name);
            try p.verify(p.Control, a, signed, peer.site);
            const head = try p.routeHead(a, signed.value, route);
            if (!std.meta.eql(head.site, try placementSite(self)))
                return error.InvalidRemoteCommand;
            var prior = try journal.control(
                store(self),
                a,
                signed.value.subject.task,
                p.controlId(signed.value),
            );
            defer if (prior) |*saved| saved.deinit();
            if (prior) |saved| {
                if (!std.meta.eql(
                    try p.digest(p.Control, a, signed.value),
                    try p.digest(p.Control, a, saved.value.control.value),
                )) return error.OperationConflict;
                if (saved.value.report) |report| {
                    try p.matchReport(a, signed.value, route, report);
                    const bytes =
                        try contracts.encodeOwned(p.ControlResolution, a, .{
                            .report = report,
                        });
                    errdefer a.free(bytes);
                    try placementAuthorizeMessage(self, a, peer, signed.value.subject, bytes);
                    return bytes;
                }
            }
            var controller = try journal.custody(store(self), a, .{
                .task = signed.value.subject.task,
            }) orelse return error.InvalidTransfer;
            defer controller.deinit();
            if (!std.meta.eql(controller.value.owner, peer.site) or
                controller.value.epoch != signed.value.controller_epoch)
                return error.StaleController;
            if (try journal.nextExecutor(store(self), a, signed.value.subject, head)) |next| {
                const bytes = try contracts.encodeOwned(p.ControlResolution, a, .{ .next = next });
                errdefer a.free(bytes);
                try placementAuthorizeMessage(self, a, peer, signed.value.subject, bytes);
                return bytes;
            }
            const report_bytes =
                try placementExecuteRoutedControl(self, a, peer_name, signed, route);
            defer a.free(report_bytes);
            var report = try contracts.decodeOwned(p.Signed(p.Report), a, report_bytes);
            defer report.deinit();
            const result =
                try contracts.encodeOwned(p.ControlResolution, a, .{
                    .report = report.value,
                });
            errdefer a.free(result);
            try placementAuthorizeMessage(self, a, peer, signed.value.subject, result);
            return result;
        }
        fn placementExecuteRoutedControl(
            self: *Self,
            a: std.mem.Allocator,
            peer_name: []const u8,
            signed: @import("../placement.zig").Signed(@import("../placement.zig").Control),
            route: []const @import("../placement.zig").Succession,
        ) ![]u8 {
            const p = @import("../placement.zig");
            const journal = @import("../placement_journal.zig");
            var parent = try self.task(a, signed.value.subject.task);
            defer parent.deinit();
            const peer = try placementPeer(self, peer_name);
            const site = try placementSite(self);
            try p.verify(p.Control, a, signed, peer.site);
            const value = signed.value;
            const head = try p.routeHead(a, value, route);
            if (!std.meta.eql(head.site, site) or value.subject.work == null or
                !std.meta.eql(
                    try wp.identity(try p.commandWork(value.command), .work),
                    value.subject.work.?,
                )) return error.InvalidRemoteCommand;
            const id = p.controlId(value);
            var prior = try journal.control(store(self), a, value.subject.task, id);
            defer if (prior) |*saved| saved.deinit();
            if (prior) |saved| {
                if (!std.meta.eql(
                    try p.digest(p.Control, a, saved.value.control.value),
                    try p.digest(p.Control, a, value),
                )) return error.OperationConflict;
                if (saved.value.report) |report| {
                    try p.matchReport(a, value, route, report);
                    const bytes = try contracts.encodeOwned(p.Signed(p.Report), a, report);
                    errdefer a.free(bytes);
                    try placementAuthorizeMessage(self, a, peer, value.subject, bytes);
                    return bytes;
                }
            }
            try admitRoutedPlacementControl(
                self,
                a,
                signed,
                route,
                peer,
                site,
                head,
                if (prior) |saved| saved.value else null,
            );
            return executePlacementControlReport(self, a, signed, route, peer, site, head);
        }
        fn admitRoutedPlacementControl(
            self: *Self,
            a: std.mem.Allocator,
            signed: @import("../placement.zig").Signed(@import("../placement.zig").Control),
            route: []const @import("../placement.zig").Succession,
            peer: @import("../placement.zig").Peer,
            site: @import("../placement.zig").Site,
            head: @import("../placement.zig").Executor,
            prior: ?@import("../placement.zig").ControlRecord,
        ) !void {
            const journal = @import("../placement_journal.zig");
            const value = signed.value;
            const id = @import("../placement.zig").controlId(value);
            var controller = try journal.custody(store(self), a, .{
                .task = value.subject.task,
            }) orelse return error.InvalidTransfer;
            defer controller.deinit();
            if (!std.meta.eql(controller.value.owner, peer.site) or
                controller.value.epoch != value.controller_epoch) return error.StaleController;
            var executor = try journal.custody(store(self), a, value.subject) orelse
                return error.InvalidTransfer;
            defer executor.deinit();
            try executor.value.requireLocal(site);
            if (executor.value.epoch != head.epoch) return error.StaleCustody;
            const route_changed = if (prior) |saved| changed: {
                if (saved.route.items.len != route.len) break :changed true;
                for (saved.route.items, route) |left, right| if (!std.meta.eql(
                    left,
                    right,
                )) break :changed true;
                break :changed false;
            } else true;
            if (route_changed) {
                try store(self).begin();
                defer store(self).rollback();
                try journal.putControl(store(self), a, .{
                    .id = id,
                    .task = value.subject.task,
                    .control = signed,
                    .route = .{ .items = route },
                });
                try self.namespace.commit("placement.receive-control");
            }
        }
        fn executePlacementControlReport(
            self: *Self,
            a: std.mem.Allocator,
            signed: @import("../placement.zig").Signed(@import("../placement.zig").Control),
            route: []const @import("../placement.zig").Succession,
            peer: @import("../placement.zig").Peer,
            site: @import("../placement.zig").Site,
            head: @import("../placement.zig").Executor,
        ) ![]u8 {
            const p = @import("../placement.zig");
            const value = signed.value;
            const id = p.controlId(value);
            // Native workspace receipts make a retry after execution but before
            // report publication idempotent. The transport never supplies an
            // environmental response or new adapter grant.
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const operation_name = try std.fmt.allocPrint(scratch.allocator(), "placement-{s}", .{
                std.fmt.bytesToHex(id, .lower),
            });
            const selected: wc.Command = if (value.expansion) |expand| .{ .context = .{ .expand = .{
                .reference = expand.reference,
                .page = expand.page,
            } } } else .{ .work = value.command };
            const reply = reply: {
                const previous = self.remote_stopped_parent;
                self.remote_stopped_parent = if (value.parent_stopped) value.subject.task else null;
                defer self.remote_stopped_parent = previous;
                break :reply try self.workspaceCommand(
                    scratch.allocator(),
                    operation_name,
                    value.subject.task,
                    selected,
                );
            };
            const lifecycle = try placementObservedWork(self, a, scratch.allocator(), value);
            const report = try p.sign(p.Report, a, self.profile.placement.?.signing_key, .{
                .control = try p.digest(p.Control, a, value),
                .executor = site,
                .custody_epoch = head.epoch,
                .reply = reply,
                .work_state = lifecycle,
            });
            const result = try contracts.encodeOwned(p.Signed(p.Report), a, report);
            errdefer a.free(result);
            try placementPutControl(
                self,
                a,
                peer,
                .{
                    .id = id,
                    .task = value.subject.task,
                    .control = signed,
                    .route = .{ .items = route },
                    .report = report,
                },
                result,
                "placement.control-report",
            );
            return result;
        }
        fn placementObservedWork(
            self: *Self,
            owner_allocator: std.mem.Allocator,
            a: std.mem.Allocator,
            value: @import("../placement.zig").Control,
        ) !@import("../placement.zig").WorkState {
            const p = @import("../placement.zig");
            var observed_work =
                try self.workspaceWork(a, value.subject.task, value.subject.work.?);
            defer observed_work.deinit();
            const outcome_bytes =
                try store(self).object(a, observed_work.value.outcome, null);
            var outcome = try data.invocation.decode(data.invocation.Outcome, a, outcome_bytes);
            defer outcome.deinit();
            const observed: p.WorkState = .{
                .observed_at = store(self).head.generation,
                .execution_revision = observed_work.value.execution_revision,
                .control_revision = observed_work.value.control_revision,
                .outcome = observed_work.value.outcome_kind,
                .cleanup_complete = cleanupComplete(outcome.value),
                .cancellation = observed_work.value.cancellation,
                .explicitly_parked = try workspaceExplicitlyParked(
                    self,
                    owner_allocator,
                    observed_work.value,
                ),
                .park_complete = try workspaceWorkSettled(
                    self,
                    owner_allocator,
                    observed_work.value,
                    false,
                    true,
                ),
            };
            var lifecycle = observed;
            lifecycle.observer_active = activeObserver(self, observed_work.value);
            return lifecycle;
        }
        pub fn placementFollowExecutor(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            control_id: state.Digest,
            next: @import("../placement.zig").Succession,
        ) !void {
            const p = @import("../placement.zig");
            const journal = @import("../placement_journal.zig");
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            try requireCustody(self, a, task_id, null);
            var saved = try journal.control(store(self), a, task_id, control_id) orelse
                return error.InvalidRemoteCommand;
            defer saved.deinit();
            const control = saved.value.control.value;
            if (!std.meta.eql(control.controller, try placementSite(self)) or
                saved.value.report != null) return error.InvalidRemoteCommand;
            const head = try p.routeHead(a, control, saved.value.route.items);
            const successor = try p.routeNext(a, control.subject, head, next);
            _ = try placementPeerAt(self, successor.site);
            var directory = try journal.custody(store(self), a, control.subject) orelse
                return error.InvalidTransfer;
            defer directory.deinit();
            if (directory.value.phase != .away) return error.CustodyNotRemote;
            const update = directory.value.epoch < successor.epoch;
            if (update and (!std.meta.eql(directory.value.owner, head.site) or
                directory.value.epoch != head.epoch)) return error.StaleCustody;
            if (directory.value.epoch == successor.epoch and
                !std.meta.eql(directory.value.owner, successor.site)) return error.InvalidTransfer;
            const route = try a.alloc(p.Succession, saved.value.route.items.len + 1);
            defer a.free(route);
            @memcpy(route[0..saved.value.route.items.len], saved.value.route.items);
            route[route.len - 1] = next;
            var updated = saved.value;
            updated.route = .{ .items = route };
            updated.last_error = null;
            try self.placement_pending.ensureUnusedCapacity(self.allocator, 1);
            try store(self).begin();
            defer store(self).rollback();
            try journal.putControl(store(self), a, updated);
            if (update) {
                directory.value.owner = successor.site;
                directory.value.epoch = successor.epoch;
                directory.value.intent = next.offer.value.intent;
                directory.value.offer = next.offer;
                directory.value.decision = next.decision;
                try journal.putCustody(store(self), a, directory.value);
            }
            try self.namespace.commit("placement.executor-succession");
            self.placement_pending.appendAssumeCapacity(.{
                .task = task_id,
                .id = control_id,
                .kind = .control,
            });
        }
        pub fn placementApplyReport(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            control_id: state.Digest,
            report: @import("../placement.zig").Signed(@import("../placement.zig").Report),
        ) !void {
            const p = @import("../placement.zig");
            const journal = @import("../placement_journal.zig");
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            var saved = try journal.control(store(self), a, task_id, control_id) orelse
                return error.InvalidRemoteCommand;
            defer saved.deinit();
            const control = saved.value.control.value;
            try p.matchReport(a, control, saved.value.route.items, report);
            if (!std.meta.eql(control.controller, try placementSite(self)))
                return error.InvalidRemoteCommand;
            if (saved.value.report) |prior| {
                if (!std.meta.eql(
                    try p.digest(p.Report, a, prior.value),
                    try p.digest(p.Report, a, report.value),
                )) return error.OperationConflict;
                return;
            }
            saved.value.report = report;
            saved.value.last_error = null;
            const wake = (parent.value.cancellation != null or parent.value.terminal()) and
                try hasLocalCustody(self, a, task_id, null);
            if (wake) {
                try ensureOwnershipCapacity(self, task_id);
                try self.runnable.ensureUnusedCapacity(self.allocator, 1);
            }
            try store(self).begin();
            defer store(self).rollback();
            try journal.putControl(store(self), a, saved.value);
            try self.namespace.commit("placement.acknowledge-control");
            if (wake) {
                claim(self, task_id);
                if (parent.value.cancellation != null) subjectAddAssumeCapacity(
                    self,
                    .{
                        .task = task_id,
                    },
                );
            }
        }
        pub fn placementFollowBehavior(
            self: *Self,
            a: std.mem.Allocator,
            decision: @import("../placement.zig").Signed(@import("../placement.zig").Behavior),
        ) !void {
            // A worker learns controller succession from both native signatures.
            // This updates a remote directory entry and cannot activate a copy.
            const p = @import("../placement.zig");
            const journal = @import("../placement_journal.zig");
            const behavior = decision.value;
            _ = try placementPeerAt(self, behavior.owner);
            try p.verify(p.Behavior, a, decision, behavior.owner);
            if (behavior.epoch != try std.math.add(u64, behavior.previous_epoch, 1))
                return error.InvalidTransfer;
            if (try store(self).recordBytes(
                a,
                "placement_behavior",
                behavior.operation,
                behavior.task,
            )) |bytes| {
                defer a.free(bytes);
                var prior = try contracts.decodeOwned(p.BehaviorRecord, a, bytes);
                defer prior.deinit();
                if (!std.meta.eql(prior.value.decision, decision)) return error.OperationConflict;
                return;
            }
            var parent = try self.task(a, behavior.task);
            defer parent.deinit();
            var custody = try journal.custody(store(self), a, .{
                .task = behavior.task,
            }) orelse return error.InvalidTransfer;
            defer custody.deinit();
            if (custody.value.phase != .away or !std.meta.eql(
                custody.value.owner,
                behavior.owner,
            ) or custody.value.epoch != behavior.previous_epoch) return error.StaleController;
            try journal.requireSettled(
                store(self),
                a,
                .{ .task = behavior.task },
                try placementSite(self),
            );
            custody.value.epoch = behavior.epoch;
            try store(self).begin();
            defer store(self).rollback();
            try store(self).createRecord(
                p.BehaviorRecord,
                "placement_behavior",
                behavior.operation,
                behavior.task,
                .{ .id = behavior.operation, .task = behavior.task, .decision = decision },
            );
            try journal.putCustody(store(self), a, custody.value);
            try self.namespace.commit("placement.controller-behavior");
        }
        pub fn placementFollowController(
            self: *Self,
            a: std.mem.Allocator,
            source_peer: []const u8,
            destination_peer: []const u8,
            offer: @import("../placement.zig").Signed(@import("../placement.zig").Offer),
            decision: @import("../placement.zig").Signed(@import("../placement.zig").Decision),
        ) !void {
            const p = @import("../placement.zig");
            const journal = @import("../placement_journal.zig");
            var parent = try self.task(a, offer.value.intent.subject.task);
            defer parent.deinit();
            const source_peer_value = try placementPeer(self, source_peer);
            const destination_peer_value =
                try placementPeer(self, destination_peer);
            try p.verify(p.Offer, a, offer, source_peer_value.site);
            try p.matchDecision(a, offer.value, decision);
            if (offer.value.intent.subject.work != null or decision.value.verdict != .accepted or
                !std.meta.eql(decision.value.destination, destination_peer_value.site))
                return error.InvalidTransfer;
            const subject = offer.value.intent.subject;
            var saved = try journal.custody(store(self), a, subject) orelse
                return error.InvalidTransfer;
            defer saved.deinit();
            const site = try placementSite(self);
            if (std.meta.eql(saved.value.owner, site) or
                std.meta.eql(decision.value.destination, site)) return error.InvalidTransfer;
            if (saved.value.epoch == decision.value.epoch and
                std.meta.eql(saved.value.owner, decision.value.destination)) return;
            if (saved.value.epoch != offer.value.intent.epoch or !std.meta.eql(
                saved.value.owner,
                source_peer_value.site,
            )) return error.StaleController;
            try journal.requireSettled(store(self), a, subject, site);
            saved.value.owner = decision.value.destination;
            saved.value.epoch = decision.value.epoch;
            saved.value.phase = .away;
            saved.value.intent = offer.value.intent;
            saved.value.offer = offer;
            saved.value.decision = decision;
            try store(self).begin();
            defer store(self).rollback();
            try journal.putCustody(store(self), a, saved.value);
            try self.namespace.commit("placement.controller-succession");
        }
        pub fn placementAbortUnsent(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("../placement.zig").Subject,
            transfer: state.Digest,
        ) !void {
            // Before an offer is published there is no possible destination
            // acceptance. Once offered, only its signed decision can release it.
            const journal = @import("../placement_journal.zig");
            var parent = try self.task(a, subject.task);
            defer parent.deinit();
            var saved = try journal.custody(store(self), a, subject) orelse
                return error.InvalidTransfer;
            defer saved.deinit();
            if (saved.value.phase != .frozen or
                saved.value.intent == null or
                saved.value.offer != null or
                !std.meta.eql(saved.value.owner, try placementSite(self)) or
                !std.meta.eql(saved.value.intent.?.transfer, transfer))
                return error.InvalidTransfer;
            saved.value.phase = .local;
            saved.value.intent = null;
            try store(self).begin();
            defer store(self).rollback();
            try journal.putCustody(store(self), a, saved.value);
            try self.namespace.commit("placement.withdraw-unsent");
        }
        pub fn placementWithdraw(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            transfer: state.Digest,
        ) !void {
            // Stop local transport before deciding whether a peer could hold an
            // offer. Published offers require that peer's durable refusal (or its
            // already committed acceptance), even when no response was received.
            const p = @import("../placement.zig");
            const journal = @import("../placement_journal.zig");
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            const site = try placementSite(self);
            var saved = try record(self, p.Move, a, "placement_move", transfer, task_id);
            defer saved.deinit();
            if (!std.meta.eql(saved.value.owner, site)) return error.CustodyNotLocal;
            if (saved.value.decision != null or saved.value.cancelled) return;
            try self.placement_pending.ensureUnusedCapacity(self.allocator, 1);
            if (self.placement_job) |running| if (running.kind == .move and
                std.meta.eql(running.id, transfer))
            {
                running.job.deinit();
                self.placement_job = null;
            };
            var i: usize = 0;
            while (i < self.placement_pending.items.len) {
                const pending = self.placement_pending.items[i];
                if (pending.kind == .move and std.meta.eql(pending.id, transfer)) {
                    _ = self.placement_pending.orderedRemove(i);
                } else i += 1;
            }
            var custody = try journal.custody(store(self), a, saved.value.subject);
            defer if (custody) |*value| value.deinit();
            const same_transfer =
                if (custody) |value|
                    if (value.value.intent) |intent|
                        std.meta.eql(intent.transfer, transfer)
                    else
                        false
                else
                    false;
            const offered = same_transfer and custody.?.value.offer != null;
            saved.value.withdraw_requested = true;
            saved.value.last_error = null;
            try store(self).begin();
            defer store(self).rollback();
            if (same_transfer and custody.?.value.decision != null) {
                saved.value.decision = custody.?.value.decision;
            } else if (!offered) {
                if (same_transfer and custody.?.value.phase == .frozen) {
                    custody.?.value.phase = .local;
                    custody.?.value.intent = null;
                    try journal.putCustody(store(self), a, custody.?.value);
                }
                saved.value.cancelled = true;
            }
            try store(self).putRecord(p.Move, "placement_move", transfer, task_id, saved.value);
            try self.namespace.commit("placement.withdraw-requested");
            if (offered and saved.value.decision == null) placementQueue(
                self,
                task_id,
                transfer,
                .move,
            );
        }
    };
}
