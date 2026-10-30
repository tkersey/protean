const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const json = @import("../json.zig");
const values = @import("../values.zig");
const wp = @import("../workspace_projection.zig");
const wc = contracts.workspace;
const archive_api = @import("../archive.zig");
const task_types = @import("types.zig");
const PlacementKind = task_types.PlacementKind;
const Work = task_types.Work;
const name = task_types.name;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const allowed = Lifecycle.allowed;
        const createCustody = Lifecycle.createCustody;
        const initialCustody = Lifecycle.initialCustody;
        const placementCompatibility = PlacementCustody.placementCompatibility;
        const placementControlExpanded = PlacementControl.placementControlExpanded;
        const placementCut = PlacementCustody.placementCut;
        const placementSite = Lifecycle.placementSite;
        const placementStatus = PlacementControl.placementStatus;
        const placementWithdraw = PlacementControl.placementWithdraw;
        const record = Records.record;
        const requireCustody = Lifecycle.requireCustody;
        const requireMovableControllerDependency = Observers.requireMovableControllerDependency;
        const snapshotRecord = Records.snapshotRecord;
        const store = Lifecycle.store;
        const Checkpoint = @import("checkpoint.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const PlacementControl = @import("placement_control.zig").Operations(Types, Self);
        const PlacementCustody = @import("placement_custody.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Observers = @import("workspace_observers.zig").Operations(Types, Self);
        pub fn retirePlacementFiles(
            self: *Self,
            a: std.mem.Allocator,
            decision: @import("../placement.zig").Signed(@import("../placement.zig").Decision),
        ) !void {
            const config = self.profile.placement orelse return;
            if (config.transport_directory == null) return;
            const p = @import("../placement.zig");
            const stage = @import("../placement_stage.zig");
            try p.verify(p.Decision, a, decision, decision.value.destination);
            const site = try placementSite(self);
            const directory = try placementDirectory(self, a);
            if (std.meta.eql(site, decision.value.destination))
                try stage.retire(a, directory, .placement, decision.value.offer_digest);
            if (std.meta.eql(site, decision.value.source))
                try stage.retire(a, directory, .outgoing, decision.value.transfer);
        }
        pub fn recoverPlacementFiles(self: *Self, a: std.mem.Allocator) !void {
            const config = self.profile.placement orelse return;
            if (config.transport_directory == null) return;
            try store(self).checkIntegrity();
            const p = @import("../placement.zig");
            var rows =
                try store(self).database.prepare("SELECT body FROM placement_decisions", &.{});
            defer rows.deinit();
            while (try rows.step() == .row) {
                var decision =
                    try contracts.decodeOwned(p.Signed(p.Decision), a, try rows.bytes(0));
                defer decision.deinit();
                try retirePlacementFiles(self, a, decision.value);
            }
        }
        pub fn placementPeer(self: *Self, peer_name: []const u8) !@import("../placement.zig").Peer {
            const config = self.profile.placement orelse return error.UnsupportedCapability;
            for (config.peers) |peer| if (same(peer.name, peer_name)) return peer;
            return error.Denied;
        }
        pub fn placementRequest(
            self: *Self,
            a: std.mem.Allocator,
            request: @import("../placement.zig").Request,
        ) !json.Value {
            const inspect_request = placementInspectRequest;
            const transfer = placementTransferRequest;
            return switch (request) {
                .identify, .challenge, .status, .cut, .compatibility => inspect_request(
                    self,
                    a,
                    request,
                ),
                .freeze, .move, .offer, .accept, .stage, .accept_staged, .refuse => transfer(
                    self,
                    a,
                    request,
                ),
                else => placementControlRequest(self, a, request),
            };
        }
        fn placementInspectRequest(
            self: *Self,
            a: std.mem.Allocator,
            request: @import("../placement.zig").Request,
        ) !json.Value {
            const p = @import("../placement.zig");
            switch (request) {
                .identify => return values.toJson(struct {
                    site: p.Site,
                    native_build: state.Digest,
                    resource_binding: state.Digest,
                }, a, .{
                    .site = try placementSite(self),
                    .native_build = self.profile.runtime_identity,
                    .resource_binding = try self.profile.resourceIdentity(
                        a,
                        self.application.image_identity,
                    ),
                }),
                .challenge => |nonce| return values.toJson(
                    p.Signed(p.Hello),
                    a,
                    try p.sign(
                        p.Hello,
                        a,
                        (self.profile.placement orelse
                            return error.UnsupportedCapability).signing_key,
                        .{
                            .site = try placementSite(self),
                            .native_build = self.profile.runtime_identity,
                            .challenge = nonce,
                        },
                    ),
                ),
                .status => |subject| return values.toJson(
                    ?p.Custody,
                    a,
                    try self.placementStatus(a, subject),
                ),
                .cut => |subject| return values.toJson(p.Cut, a, try self.placementCut(a, subject)),
                .compatibility => |subject| return values.toJson(
                    p.Compatibility,
                    a,
                    try self.placementCompatibility(a, subject),
                ),
                else => unreachable,
            }
        }
        fn placementTransferRequest(
            self: *Self,
            a: std.mem.Allocator,
            request: @import("../placement.zig").Request,
        ) !json.Value {
            const p = @import("../placement.zig");
            switch (request) {
                .freeze => |v| return values.toJson(
                    p.Intent,
                    a,
                    try self.placementFreeze(a, v.subject, v.peer.bytes, v.expected, v.transfer),
                ),
                .move => |v| return values.toJson(
                    p.Signed(p.Decision),
                    a,
                    try self.placementMove(a, v.subject, v.peer.bytes, v.expected, v.transfer),
                ),
                .offer => |v| return values.toJson(
                    p.Signed(p.Offer),
                    a,
                    try self.placementOffer(a, v.subject, v.peer.bytes, v.path.bytes),
                ),
                .accept => |v| return values.toJson(
                    p.Signed(p.Decision),
                    a,
                    try self.placementAccept(
                        a,
                        v.operation.bytes,
                        v.peer.bytes,
                        v.offer,
                        v.path.bytes,
                    ),
                ),
                .stage => |v| return placementStageRequest(self, a, v),
                .accept_staged => |v| return placementAcceptStagedRequest(self, a, v),
                .refuse => |v| return values.toJson(
                    p.Signed(p.Decision),
                    a,
                    try self.placementRefuse(a, v.peer.bytes, v.offer, v.reason),
                ),
                else => unreachable,
            }
        }
        fn placementControlRequest(
            self: *Self,
            a: std.mem.Allocator,
            request: @import("../placement.zig").Request,
        ) !json.Value {
            const p = @import("../placement.zig");
            switch (request) {
                .decision => |v| try self.placementApplyDecision(a, v.subject, v.decision),
                .abort_unsent => |v| try self.placementAbortUnsent(a, v.subject, v.transfer),
                .withdraw => |v| try self.placementWithdraw(a, v.task, v.transfer),
                .control => |v| {
                    const bytes =
                        try self.placementControl(a, v.operation.bytes, v.task, v.command);
                    defer a.free(bytes);
                    var signed = try contracts.decodeOwned(p.Signed(p.Control), a, bytes);
                    defer signed.deinit();
                    return values.toJson(p.Signed(p.Control), a, signed.value);
                },
                .execute_control => |v| {
                    const bytes = try self.placementExecuteControl(a, v.peer.bytes, v.control);
                    defer a.free(bytes);
                    var signed = try contracts.decodeOwned(p.Signed(p.Report), a, bytes);
                    defer signed.deinit();
                    return values.toJson(p.Signed(p.Report), a, signed.value);
                },
                .resolve_control => |v| {
                    const bytes =
                        try self.placementResolveControl(a, v.peer.bytes, v.control, v.route.items);
                    defer a.free(bytes);
                    var resolution = try contracts.decodeOwned(p.ControlResolution, a, bytes);
                    defer resolution.deinit();
                    return values.toJson(p.ControlResolution, a, resolution.value);
                },
                .report => |v| try self.placementApplyReport(a, v.task, v.control, v.report),
                .follow_controller_behavior => |v| try self.placementFollowBehavior(a, v),
                .follow_controller => |v| try self.placementFollowController(
                    a,
                    v.source.bytes,
                    v.destination.bytes,
                    v.offer,
                    v.decision,
                ),
                .follow_controller_proof => |v| try self.placementFollowController(
                    a,
                    (try placementPeerAt(self, v.offer.value.intent.source)).name,
                    (try placementPeerAt(self, v.decision.value.destination)).name,
                    v.offer,
                    v.decision,
                ),
                else => unreachable,
            }
            return json.object();
        }
        fn placementStageRequest(
            self: *Self,
            a: std.mem.Allocator,
            v: @FieldType(@import("../placement.zig").Request, "stage"),
        ) !json.Value {
            const p = @import("../placement.zig");
            try allowed(self);
            const peer = try placementPeer(self, v.peer.bytes);
            try p.verify(p.Offer, a, v.offer, peer.site);
            if (!std.meta.eql(v.offer.value.intent.destination, try placementSite(self)))
                return error.InvalidTransfer;
            if (try @import("../placement_journal.zig").decision(
                store(self),
                a,
                v.offer.value.intent.transfer,
            )) |saved| {
                var prior = saved;
                defer prior.deinit();
                try p.matchDecision(a, v.offer.value, prior.value);
                try retirePlacementFiles(self, a, prior.value);
                return values.toJson(u64, a, v.offer.value.archive_bytes);
            }
            if (peer.archive_limit) |limit| if (v.offer.value.archive_bytes > limit)
                return error.Capacity;
            return values.toJson(
                u64,
                a,
                try @import("../placement_stage.zig").write(
                    a,
                    self.io,
                    try placementDirectory(self, a),
                    self.profile.placement.?.staging_limits,
                    v.offer.value,
                    v.offset,
                    v.bytes.bytes,
                ),
            );
        }
        fn placementAcceptStagedRequest(
            self: *Self,
            a: std.mem.Allocator,
            v: @FieldType(@import("../placement.zig").Request, "accept_staged"),
        ) !json.Value {
            const p = @import("../placement.zig");
            const path = try @import("../placement_stage.zig").path(
                a,
                try placementDirectory(self, a),
                v.offer.value,
            );
            defer a.free(path);
            return values.toJson(
                p.Signed(p.Decision),
                a,
                try self.placementAccept(a, v.operation.bytes, v.peer.bytes, v.offer, path),
            );
        }
        pub fn placementDirectory(self: *Self, a: std.mem.Allocator) ![]const u8 {
            const configured = self.profile.placement orelse return error.UnsupportedCapability;
            const path = configured.transport_directory orelse return error.UnsupportedCapability;
            const c = @import("native_c");
            const dir = try @import("../namespace.zig").openDirectory(a, path, false, true);
            defer _ = c.close(dir);
            var spool: c.struct_protean_native_stat = undefined;
            var owner: c.struct_protean_native_stat = undefined;
            if (c.protean_native_fstat(dir, &spool) != 0 or c.protean_native_fstat(
                self.namespace.directory,
                &owner,
            ) != 0) return error.StorageUnavailable;
            var cursor = c.dup(dir);
            if (cursor < 0) return error.StorageUnavailable;
            defer _ = c.close(cursor);
            var reached_root = false;
            while (!reached_root) {
                if (spool.st_dev == owner.st_dev and spool.st_ino == owner.st_ino)
                    return error.UnsafeStatePath;
                const parent =
                    c.openat(cursor, "..", c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
                if (parent < 0) return error.StorageUnavailable;
                var ancestor: c.struct_protean_native_stat = undefined;
                if (c.protean_native_fstat(parent, &ancestor) != 0) {
                    _ = c.close(parent);
                    return error.StorageUnavailable;
                }
                if (ancestor.st_dev == spool.st_dev and ancestor.st_ino == spool.st_ino) {
                    _ = c.close(parent);
                    reached_root = true;
                    continue;
                }
                _ = c.close(cursor);
                cursor = parent;
                spool = ancestor;
            }
            return path;
        }
        pub fn placementPeerAt(
            self: *Self,
            site: @import("../placement.zig").Site,
        ) !@import("../placement.zig").Peer {
            const config = self.profile.placement orelse return error.UnsupportedCapability;
            for (config.peers) |peer| if (std.meta.eql(peer.site, site)) return peer;
            return error.Denied;
        }
        fn placementSubject(
            task_id: state.TaskId,
            selected: wc.PlacementSubject,
        ) !@import("../placement.zig").Subject {
            return .{ .task = task_id, .work = switch (selected) {
                .controller => null,
                .work => |ref| try wp.identity(ref, .work),
            } };
        }
        pub fn placementReplyCopy(a: std.mem.Allocator, reply: wc.Reply) !wc.Reply {
            var result = reply;
            result.observation_json.bytes = try a.dupe(u8, reply.observation_json.bytes);
            inline for (.{ "selected_view", "program", "evidence" }) |field|
                if (@field(result, field)) |*ref| {
                    ref.id.bytes = try a.dupe(u8, ref.id.bytes);
                };
            return result;
        }
        pub fn placementQueue(
            self: *Self,
            task_id: state.TaskId,
            id: state.Digest,
            kind: PlacementKind,
        ) void {
            if (self.placement_job) |running| if (std.meta.eql(running.id, id) and
                running.kind == kind) return;
            for (self.placement_pending.items) |pending| if (std.meta.eql(pending.id, id) and
                pending.kind == kind) return;
            self.placement_pending.appendAssumeCapacity(.{
                .task = task_id,
                .id = id,
                .kind = kind,
            });
        }
        fn placementFailure(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
            kind: PlacementKind,
            err: anyerror,
        ) !void {
            const p = @import("../placement.zig");
            try store(self).begin();
            defer store(self).rollback();
            switch (kind) {
                .move => {
                    var saved = try record(self, p.Move, a, "placement_move", id, task_id);
                    defer saved.deinit();
                    saved.value.last_error = try name(@errorName(err));
                    try store(self).putRecord(p.Move, "placement_move", id, task_id, saved.value);
                },
                .control => {
                    var saved =
                        try record(self, p.ControlRecord, a, "placement_control", id, task_id);
                    defer saved.deinit();
                    saved.value.last_error = try name(@errorName(err));
                    try store(self).putRecord(
                        p.ControlRecord,
                        "placement_control",
                        id,
                        task_id,
                        saved.value,
                    );
                },
            }
            try self.namespace.commit("placement.transport-blocked");
        }
        fn placementStartJob(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
            kind: PlacementKind,
        ) !?*@import("../placement_job.zig").Job {
            return switch (kind) {
                .move => placementStartMove(self, a, task_id, id),
                .control => placementStartControl(self, a, task_id, id),
            };
        }
        fn placementStartMove(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
        ) !?*@import("../placement_job.zig").Job {
            const p = @import("../placement.zig");
            const jobs = @import("../placement_job.zig");
            var saved = try record(self, p.Move, a, "placement_move", id, task_id);
            defer saved.deinit();
            if (!std.meta.eql(saved.value.owner, try placementSite(self)))
                return error.CustodyNotLocal;
            if (saved.value.decision != null or saved.value.cancelled) return null;
            const subject = saved.value.subject;
            const prior = try self.placementStatus(a, subject);
            if (try placementRecoverMove(self, task_id, id, &saved.value, prior)) return null;
            if (saved.value.withdraw_requested)
                return try placementWithdrawJob(self, a, id, subject, saved.value, prior);
            const expected = if (prior) |custody| expected: {
                if (custody.intent) |intent| if (std.meta.eql(
                    intent.transfer,
                    id,
                )) break :expected intent.cut;
                if (custody.epoch != saved.value.request.custody_epoch)
                    return error.StaleCustody;
                break :expected try self.placementCut(a, subject);
            } else try self.placementCut(a, subject);
            _ = try self.placementFreeze(a, subject, saved.value.request.site.bytes, expected, id);
            const path = try std.fmt.allocPrint(a, "{s}/outgoing-{s}.par", .{
                try placementDirectory(self, a),
                std.fmt.bytesToHex(id, .lower),
            });
            defer a.free(path);
            const offer = try self.placementOffer(a, subject, saved.value.request.site.bytes, path);
            return try jobs.Job.start(self.allocator, self.io, try placementPeer(
                self,
                saved.value.request.site.bytes,
            ), .{ .move = .{ .offer = offer, .path = .{ .bytes = path } } });
        }
        fn placementStartControl(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            id: state.Digest,
        ) !?*@import("../placement_job.zig").Job {
            const p = @import("../placement.zig");
            const jobs = @import("../placement_job.zig");
            var saved =
                try record(self, p.ControlRecord, a, "placement_control", id, task_id);
            defer saved.deinit();
            if (saved.value.report != null) return null;
            try requireCustody(self, a, task_id, null);
            if (!std.meta.eql(
                saved.value.control.value.controller,
                try placementSite(self),
            )) return error.CustodyNotLocal;
            const lineage =
                try @import("../placement_journal.zig").controllerLineage(store(self), a, task_id);
            defer a.free(lineage);
            const head = try p.routeHead(a, saved.value.control.value, saved.value.route.items);
            const peer = try placementPeerAt(self, head.site);
            const input: jobs.Input = .{
                .control = .{
                    .message = saved.value.control,
                    .route = saved.value.route,
                    .lineage = .{ .items = lineage },
                },
            };
            const bytes = try contracts.encodeOwned(jobs.Input, a, input);
            defer a.free(bytes);
            try placementAuthorizeMessage(self, a, peer, saved.value.control.value.subject, bytes);
            return try jobs.Job.start(self.allocator, self.io, peer, input);
        }
        fn placementRecoverMove(
            self: *Self,
            task_id: state.TaskId,
            id: state.Digest,
            saved: *@import("../placement.zig").Move,
            prior: ?@import("../placement.zig").Custody,
        ) !bool {
            const p = @import("../placement.zig");
            if (prior) |custody| if (custody.intent) |intent| {
                if (std.meta.eql(intent.transfer, id) and custody.decision != null) {
                    saved.decision = custody.decision;
                    saved.last_error = null;
                    try store(self).begin();
                    defer store(self).rollback();
                    try store(self).putRecord(p.Move, "placement_move", id, task_id, saved.*);
                    try self.namespace.commit("placement.move-recovered");
                    return true;
                }
            };
            return false;
        }
        fn placementWithdrawJob(
            self: *Self,
            a: std.mem.Allocator,
            id: state.Digest,
            subject: @import("../placement.zig").Subject,
            saved: @import("../placement.zig").Move,
            prior: ?@import("../placement.zig").Custody,
        ) !*@import("../placement_job.zig").Job {
            const jobs = @import("../placement_job.zig");
            const custody = prior orelse return error.InvalidTransfer;
            const offer = custody.offer orelse return error.InvalidTransfer;
            if (!std.meta.eql(offer.value.intent.transfer, id)) return error.InvalidTransfer;
            const peer = try placementPeer(self, saved.request.site.bytes);
            const input: jobs.Input = .{ .withdraw = offer };
            const bytes = try contracts.encodeOwned(jobs.Input, a, input);
            defer a.free(bytes);
            try placementAuthorizeMessage(self, a, peer, subject, bytes);
            return try jobs.Job.start(self.allocator, self.io, peer, input);
        }
        pub fn pumpPlacement(self: *Self, a: std.mem.Allocator) !bool {
            if (self.placement_job) |running| {
                if (!running.job.finished.load(.acquire)) return false;
                defer {
                    running.job.deinit();
                    self.placement_job = null;
                }
                const result = running.job.result catch |err| {
                    try placementFailure(self, a, running.task, running.id, running.kind, err);
                    return true;
                };
                try publishPlacementJob(self, a, running, result);
                return true;
            }
            if (self.placement_pending.items.len == 0 or self.work != null) return false;
            const selected = self.placement_pending.orderedRemove(0);
            const job =
                placementStartJob(self, a, selected.task, selected.id, selected.kind) catch |err| {
                    if (store(self).fenced or err == error.OutOfMemory or
                        err == error.StorageUnavailable)
                        return err;
                    try placementFailure(self, a, selected.task, selected.id, selected.kind, err);
                    return true;
                };
            if (job) |started| self.placement_job = .{
                .task = selected.task,
                .id = selected.id,
                .kind = selected.kind,
                .job = started,
            };
            return true;
        }
        fn publishPlacementJob(
            self: *Self,
            a: std.mem.Allocator,
            running: anytype,
            result: @import("../placement_job.zig").Result,
        ) !void {
            const p = @import("../placement.zig");
            switch (result) {
                .decision => |decision| {
                    var saved =
                        try record(self, p.Move, a, "placement_move", running.id, running.task);
                    defer saved.deinit();
                    try self.placementApplyDecision(a, saved.value.subject, decision);
                    saved.value.decision = decision;
                    saved.value.last_error = null;
                    try store(self).begin();
                    defer store(self).rollback();
                    try store(self).putRecord(
                        p.Move,
                        "placement_move",
                        running.id,
                        running.task,
                        saved.value,
                    );
                    try self.namespace.commit("placement.move-complete");
                },
                .report => |bytes| {
                    var resolution = try contracts.decodeOwned(p.ControlResolution, a, bytes);
                    defer resolution.deinit();
                    switch (resolution.value) {
                        .report => |report| try self.placementApplyReport(
                            a,
                            running.task,
                            running.id,
                            report,
                        ),
                        .next => |next| {
                            // The joined job still occupies placement_job;
                            // enqueue directly after reserving before commit.
                            self.placementFollowExecutor(
                                a,
                                running.task,
                                running.id,
                                next,
                            ) catch |err| {
                                if (store(self).fenced or err == error.OutOfMemory or
                                    err == error.StorageUnavailable)
                                    return err;
                                try placementFailure(
                                    self,
                                    a,
                                    running.task,
                                    running.id,
                                    .control,
                                    err,
                                );
                            };
                        },
                    }
                },
            }
        }
        pub fn placementModel(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            task_id: state.TaskId,
            request: wc.Placement,
        ) !wc.Reply {
            // Model-selected placement is a native operation with an immutable
            // signed observation. A move queues transport only after this receipt;
            // it cannot retire the controller from inside its own callback.
            const p = @import("../placement.zig");
            const site = try placementSite(self);
            const id = p.operationId(site, task_id, operation_id, .action);
            if (try store(self).recordBytes(a, "placement_action", id, task_id)) |bytes| {
                defer a.free(bytes);
                var prior = try contracts.decodeOwned(p.ActionRecord, a, bytes);
                defer prior.deinit();
                try p.verify(p.Action, a, prior.value.action, site);
                const wanted = try contracts.encodeOwned(wc.Placement, a, request);
                defer a.free(wanted);
                const actual =
                    try contracts.encodeOwned(wc.Placement, a, prior.value.action.value.request);
                defer a.free(actual);
                if (!same(wanted, actual)) return error.OperationConflict;
                return placementReplyCopy(a, prior.value.action.value.reply);
            }
            try requireCustody(self, a, task_id, null);
            if (self.workspace_replay != null) return error.InvalidArchive;
            try self.placement_pending.ensureUnusedCapacity(self.allocator, 1);
            var placement: ModelPlacement = .{
                .service = self,
                .a = a,
                .task_id = task_id,
                .site = site,
                .id = id,
                .operation_id = operation_id,
                .request = request,
            };
            try placement.observe();
            return placement.publish();
        }
        const ModelPlacement = modelPlacementType();
        fn modelPlacementType() type {
            return struct {
                service: *Self,
                a: std.mem.Allocator,
                task_id: state.TaskId,
                site: @import("../placement.zig").Site,
                id: state.Digest,
                operation_id: []const u8,
                request: wc.Placement,
                queued: ?struct { id: state.Digest, kind: PlacementKind } = null,
                new_move: ?@import("../placement.zig").Move = null,
                observation: json.Value = json.object(),
                fn observe(placement: *@This()) !void {
                    switch (placement.request) {
                        .sites => try placement.observeSites(),
                        .inspect => |selected| try placement.observeInspect(selected),
                        .assess => |selected| try placement.observeAssess(selected),
                        .move => |selected| try placement.observeMove(selected),
                        .retry, .withdraw => try placement.observeRetry(),
                        .control, .expand => try placement.observeControl(),
                    }
                }
                fn observeSites(placement: *@This()) !void {
                    const p = @import("../placement.zig");
                    var sites: std.array_list.Managed(json.Value) = .init(placement.a);
                    for (placement.service.profile.placement.?.peers) |peer| {
                        var item = json.object();
                        try json.put(
                            placement.a,
                            &item,
                            "name",
                            json.string(try placement.a.dupe(u8, peer.name)),
                        );
                        try json.put(
                            placement.a,
                            &item,
                            "site",
                            try values.toJson(p.Site, placement.a, peer.site),
                        );
                        try json.put(
                            placement.a,
                            &item,
                            "transport",
                            .{ .bool = peer.channel != null },
                        );
                        try json.put(placement.a, &item, "compatibility", try values.toJson(
                            p.Compatibility,
                            placement.a,
                            peer.compatibility,
                        ));
                        try json.put(placement.a, &item, "guarded_transfer", .{ .bool = false });
                        try sites.append(item);
                    }
                    try json.put(placement.a, &placement.observation, "sites", .{ .array = sites });
                }
                fn observeInspect(
                    placement: *@This(),
                    selected: @FieldType(wc.Placement, "inspect"),
                ) !void {
                    const p = @import("../placement.zig");
                    const subject = try placementSubject(placement.task_id, selected);
                    try json.put(
                        placement.a,
                        &placement.observation,
                        "custody",
                        try values.toJson(
                            ?p.Custody,
                            placement.a,
                            try placementStatus(placement.service, placement.a, subject),
                        ),
                    );
                    try json.put(
                        placement.a,
                        &placement.observation,
                        "retained_cut",
                        try values.toJson(
                            p.Cut,
                            placement.a,
                            try placementCut(placement.service, placement.a, subject),
                        ),
                    );
                }
                fn observeAssess(
                    placement: *@This(),
                    selected: @FieldType(wc.Placement, "assess"),
                ) !void {
                    const p = @import("../placement.zig");
                    const subject = try placementSubject(placement.task_id, selected.subject);
                    const peer = try placementPeer(placement.service, selected.site.bytes);
                    const profiles_match = std.meta.eql(
                        peer.compatibility,
                        try placementCompatibility(placement.service, placement.a, subject),
                    ) and std.meta.eql(
                        peer.resource_binding,
                        try placement.service.profile.resourceIdentity(
                            placement.a,
                            placement.service.application.image_identity,
                        ),
                    );
                    try json.put(
                        placement.a,
                        &placement.observation,
                        "compatible",
                        .{ .bool = profiles_match },
                    );
                    try json.put(
                        placement.a,
                        &placement.observation,
                        "transport",
                        .{ .bool = peer.channel != null },
                    );
                    try json.put(
                        placement.a,
                        &placement.observation,
                        "disclosure",
                        json.string("checked over the exact private closure when staging"),
                    );
                    try json.put(
                        placement.a,
                        &placement.observation,
                        "cut",
                        try values.toJson(
                            p.Cut,
                            placement.a,
                            try placementCut(placement.service, placement.a, subject),
                        ),
                    );
                }
                fn newMove(
                    placement: *@This(),
                    selected: @FieldType(wc.Placement, "move"),
                    move_id: state.Digest,
                ) !void {
                    const subject = try placementSubject(placement.task_id, selected.subject);
                    try requireCustody(
                        placement.service,
                        placement.a,
                        placement.task_id,
                        subject.work,
                    );
                    try requireMovableControllerDependency(placement.service, placement.a, subject);
                    const custody_value = (try placementStatus(
                        placement.service,
                        placement.a,
                        subject,
                    )) orelse try initialCustody(
                        placement.service,
                        placement.a,
                        subject,
                        placement.site,
                    );
                    try custody_value.requireLocal(placement.site);
                    if (custody_value.epoch != selected.custody_epoch)
                        return error.StaleCustody;
                    placement.new_move = .{
                        .id = move_id,
                        .task = placement.task_id,
                        .owner = placement.site,
                        .action = undefined,
                        .request = selected,
                        .subject = subject,
                        .expected = null,
                    };
                    try json.put(
                        placement.a,
                        &placement.observation,
                        "transfer",
                        json.string(try placement.a.dupe(u8, &std.fmt.bytesToHex(move_id, .lower))),
                    );
                    try json.put(
                        placement.a,
                        &placement.observation,
                        "status",
                        json.string("queued"),
                    );
                    placement.queued = .{ .id = move_id, .kind = .move };
                }
                fn observeMove(
                    placement: *@This(),
                    selected: @FieldType(wc.Placement, "move"),
                ) !void {
                    const p = @import("../placement.zig");
                    if (selected.operation.bytes.len == 0) return error.InvalidOperation;
                    const peer = try placementPeer(placement.service, selected.site.bytes);
                    if (peer.channel == null) return error.UnsupportedCapability;
                    _ = try placementDirectory(placement.service, placement.a);
                    const move_id = p.operationId(
                        placement.site,
                        placement.task_id,
                        selected.operation.bytes,
                        .move,
                    );
                    if (try store(placement.service).recordBytes(
                        placement.a,
                        "placement_move",
                        move_id,
                        placement.task_id,
                    )) |bytes| {
                        defer placement.a.free(bytes);
                        var prior = try contracts.decodeOwned(p.Move, placement.a, bytes);
                        defer prior.deinit();
                        const wanted =
                            try contracts.encodeOwned(@TypeOf(selected), placement.a, selected);
                        defer placement.a.free(wanted);
                        const actual = try contracts.encodeOwned(
                            @TypeOf(selected),
                            placement.a,
                            prior.value.request,
                        );
                        defer placement.a.free(actual);
                        if (!same(wanted, actual)) return error.OperationConflict;
                        placement.observation = try values.toJson(p.Move, placement.a, prior.value);
                        if (prior.value.decision == null and
                            !prior.value.cancelled) placement.queued = .{
                            .id = move_id,
                            .kind = .move,
                        };
                    } else {
                        try placement.newMove(selected, move_id);
                    }
                }
                fn observeRetry(placement: *@This()) !void {
                    const p = @import("../placement.zig");
                    const selected_operation =
                        if (placement.request == .retry)
                            placement.request.retry.operation
                        else
                            placement.request.withdraw.operation;
                    const move_id = p.operationId(
                        placement.site,
                        placement.task_id,
                        selected_operation.bytes,
                        .move,
                    );
                    if (placement.request == .withdraw) try placementWithdraw(
                        placement.service,
                        placement.a,
                        placement.task_id,
                        move_id,
                    );
                    var prior = try record(
                        placement.service,
                        p.Move,
                        placement.a,
                        "placement_move",
                        move_id,
                        placement.task_id,
                    );
                    defer prior.deinit();
                    if (!std.meta.eql(prior.value.owner, placement.site))
                        return error.CustodyNotLocal;
                    placement.observation = try values.toJson(p.Move, placement.a, prior.value);
                    if (prior.value.decision == null and
                        !prior.value.cancelled) placement.queued = .{
                        .id = move_id,
                        .kind = .move,
                    };
                }
                fn observeControl(placement: *@This()) !void {
                    const p = @import("../placement.zig");
                    const journal = @import("../placement_journal.zig");
                    const expanded = placement.request == .expand;
                    const selected_command: wc.Work = if (expanded) .{ .inspect = .{
                        .work = placement.request.expand.work,
                    } } else placement.request.control.command;
                    const selected_operation =
                        if (expanded)
                            placement.request.expand.operation
                        else
                            placement.request.control.operation;
                    const bytes = try placementControlExpanded(
                        placement.service,
                        placement.a,
                        selected_operation.bytes,
                        placement.task_id,
                        selected_command,
                        if (expanded) .{
                            .reference = placement.request.expand.reference,
                            .page = placement.request.expand.page,
                        } else null,
                        true,
                        null,
                    );
                    defer placement.a.free(bytes);
                    var control =
                        try contracts.decodeOwned(p.Signed(p.Control), placement.a, bytes);
                    defer control.deinit();
                    const control_id = p.controlId(control.value.value);
                    var saved = try journal.control(
                        store(placement.service),
                        placement.a,
                        placement.task_id,
                        control_id,
                    ) orelse return error.CorruptState;
                    defer saved.deinit();
                    try placement.observeControlRecord(control_id, saved.value);
                }
                fn observeControlRecord(
                    placement: *@This(),
                    control_id: state.Digest,
                    saved: @import("../placement.zig").ControlRecord,
                ) !void {
                    const p = @import("../placement.zig");
                    if (saved.report) |report| {
                        // Remote references remain owned by that executor.
                        // An observation cannot mint local value/view custody.
                        try json.put(
                            placement.a,
                            &placement.observation,
                            "remote_reply",
                            try values.toJson(wc.Reply, placement.a, report.value.reply),
                        );
                    } else {
                        const head =
                            try p.routeHead(placement.a, saved.control.value, saved.route.items);
                        const peer = try placementPeerAt(placement.service, head.site);
                        if (peer.channel == null) return error.UnsupportedCapability;
                        try json.put(
                            placement.a,
                            &placement.observation,
                            "control",
                            json.string(
                                try placement.a.dupe(u8, &std.fmt.bytesToHex(control_id, .lower)),
                            ),
                        );
                        try json.put(
                            placement.a,
                            &placement.observation,
                            "status",
                            json.string("queued"),
                        );
                        try json.put(
                            placement.a,
                            &placement.observation,
                            "last_error",
                            try values.toJson(?state.Name, placement.a, saved.last_error),
                        );
                        placement.queued = .{ .id = control_id, .kind = .control };
                    }
                }

                fn publish(placement: *@This()) !wc.Reply {
                    const p = @import("../placement.zig");
                    const journal = @import("../placement_journal.zig");
                    const reply: wc.Reply = .{ .disposition = .observed, .observation_json = .{
                        .bytes = try json.canonical(placement.a, placement.observation),
                    } };
                    const signed = try p.sign(
                        p.Action,
                        placement.a,
                        placement.service.profile.placement.?.signing_key,
                        .{
                            .id = placement.id,
                            .task = placement.task_id,
                            .owner = placement.site,
                            .operation = try name(placement.operation_id),
                            .request = placement.request,
                            .reply = reply,
                        },
                    );
                    try store(placement.service).begin();
                    defer store(placement.service).rollback();
                    var controller = try journal.custody(
                        store(placement.service),
                        placement.a,
                        .{ .task = placement.task_id },
                    );
                    defer if (controller) |*saved| saved.deinit();
                    if (controller == null) try createCustody(
                        placement.service,
                        placement.a,
                        placement.task_id,
                        null,
                    );
                    try store(placement.service).createRecord(
                        p.ActionRecord,
                        "placement_action",
                        placement.id,
                        placement.task_id,
                        .{
                            .id = placement.id,
                            .task = placement.task_id,
                            .action = signed,
                        },
                    );
                    if (placement.new_move) |*move| {
                        move.action = try snapshotRecord(
                            placement.service,
                            p.ActionRecord,
                            placement.a,
                            "placement_action",
                            placement.id,
                            placement.task_id,
                        );
                        try store(placement.service).createRecord(
                            p.Move,
                            "placement_move",
                            move.id,
                            placement.task_id,
                            move.*,
                        );
                    }
                    try placement.service.namespace.commit("placement.model-action");
                    if (placement.queued) |pending| placementQueue(
                        placement.service,
                        placement.task_id,
                        pending.id,
                        pending.kind,
                    );
                    return reply;
                }
            };
        }
        pub fn placementAuthorizeMessage(
            self: *Self,
            a: std.mem.Allocator,
            peer: @import("../placement.zig").Peer,
            subject: @import("../placement.zig").Subject,
            message_bytes: []const u8,
        ) !void {
            // Historical signatures preserve identity; each new disclosure still
            // needs the launch's current policy. The temporary object lets the
            // policy inspect the exact bytes, without publishing a new operation.
            var parent = try self.task(a, subject.task);
            defer parent.deinit();
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const closure =
                try archive_api.disclosureClosure(scratch.allocator(), store(self), subject.task);
            const refs = try scratch.allocator().alloc(state.Reference, closure.len + 1);
            @memcpy(refs[0..closure.len], closure);
            try store(self).begin();
            defer store(self).rollback();
            refs[closure.len] = try store(self).putObject(message_bytes);
            try peer.disclose(peer.context, subject, refs);
        }
        pub fn placementPutControl(
            self: *Self,
            a: std.mem.Allocator,
            peer: @import("../placement.zig").Peer,
            record_value: @import("../placement.zig").ControlRecord,
            message_bytes: []const u8,
            label: []const u8,
        ) !void {
            // The message's exact bytes join the current private task closure.
            // Disclosure admission happens before publication and transport.
            var parent = try self.task(a, record_value.task);
            defer parent.deinit();
            var scratch = std.heap.ArenaAllocator.init(a);
            defer scratch.deinit();
            const closure = try archive_api.disclosureClosure(
                scratch.allocator(),
                store(self),
                record_value.task,
            );
            const refs = try scratch.allocator().alloc(state.Reference, closure.len + 1);
            @memcpy(refs[0..closure.len], closure);
            try store(self).begin();
            defer store(self).rollback();
            refs[closure.len] = try store(self).putObject(message_bytes);
            try peer.disclose(peer.context, record_value.control.value.subject, refs);
            try @import("../placement_journal.zig").putControl(store(self), a, record_value);
            try self.namespace.commit(label);
        }
    };
}
