const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const kosmos = @import("kosmos");
const workspace = @import("../workspace_state.zig");
const archive_api = @import("../archive.zig");
const task_types = @import("types.zig");
const SelectedRuntime = task_types.SelectedRuntime;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const allowed = Lifecycle.allowed;
        const compatible = Controller.compatible;
        const compilerReference = Compiler.compilerReference;
        const delegationCurrent = Execution.delegationCurrent;
        const initialCustody = Lifecycle.initialCustody;
        const placementDirectory = Transport.placementDirectory;
        const placementPeer = Transport.placementPeer;
        const placementSite = Lifecycle.placementSite;
        const prepareCompilerFacts = Compiler.prepareCompilerFacts;
        const record = Records.record;
        const requireMovableControllerDependency = Observers.requireMovableControllerDependency;
        const requireObserverMobility = Observers.requireObserverMobility;
        const retainRootOperation = Controller.retainRootOperation;
        const retire = Lifecycle.retire;
        const retirePlacementFiles = Transport.retirePlacementFiles;
        const rootImage = Controller.rootImage;
        const rootOperation = Controller.rootOperation;
        const store = Lifecycle.store;
        const subjectRemove = Scheduling.subjectRemove;
        const validateArchiveAdmissions = Occurrences.validateArchiveAdmissions;
        const validateWorkspaceArchive = Snapshots.validateWorkspaceArchive;
        const workspaceIds = Recovery.workspaceIds;
        const workspaceRuntime = Programs.workspaceRuntime;
        const Occurrences = @import("archive_occurrences.zig").Operations(Types, Self);
        const Compiler = @import("compiler_preparation.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const PlacementControl = @import("placement_control.zig").Operations(Types, Self);
        const Transport = @import("placement_transport.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Recovery = @import("work_recovery.zig").Operations(Types, Self);
        const Execution = @import("workspace_execution.zig").Operations(Types, Self);
        const Observers = @import("workspace_observers.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        pub fn placementCompatibility(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("../placement.zig").Subject,
        ) !@import("../placement.zig").Compatibility {
            var parent = try self.task(a, subject.task);
            defer parent.deinit();
            try requireObserverMobility(self, a, parent.value, subject.work);
            // Compatibility belongs to the admitted artifact. Inspecting it
            // must not restore execution or acquire a publication obligation.
            var selected: ?SelectedRuntime = null;
            defer if (selected) |*runtime| runtime.deinit();
            if (subject.work) |id| {
                var child = try self.workspaceWork(a, subject.task, id);
                defer child.deinit();
                if (child.value.guard != null) return error.GuardedMobilityUnsupported;
                if (child.value.runtime) |ref| {
                    selected = try workspaceRuntime(
                        self,
                        a,
                        subject.task,
                        ref.digest,
                        child.value.program,
                    );
                    if (!std.meta.eql(ref, selected.?.record.value.artifact))
                        return error.InvalidRuntime;
                }
            } else if (parent.value.controller_runtime) |ref| {
                selected = try workspaceRuntime(self, a, subject.task, ref.digest, null);
                var program =
                    try self.workspaceProgram(a, subject.task, selected.?.record.value.program);
                defer program.deinit();
                if (!std.meta.eql(ref, selected.?.record.value.artifact) or
                    !std.meta.eql(
                        try rootImage(self, a, parent.value),
                        program.value.description.image,
                    )) return error.InvalidRuntime;
            }
            var packaged = try self.program.retainRuntime();
            defer packaged.deinit();
            const manifest =
                if (selected) |runtime|
                    runtime.admitted.content.value.manifest
                else
                    packaged.content.value.manifest;
            const validation = if (selected) |runtime| runtime.record.value.validation else null;
            return .{
                .base = storage.digest(manifest.requirements.base),
                .admission = storage.digest(manifest.requirements.admission),
                .bridge = storage.digest(manifest.requirements.bridge),
                .semantics = manifest.source,
                .private_state = storage.digest(kosmos.RuntimeCapsule.identity),
                .semantic_root = if (validation) |fact| fact.root else null,
                .semantic_checker = if (validation) |fact|
                    storage.digest(fact.checker.bytes)
                else
                    null,
            };
        }
        pub fn placementCut(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("../placement.zig").Subject,
        ) !@import("../placement.zig").Cut {
            const p = @import("../placement.zig");
            if (subject.work) |id| {
                var child = try self.workspaceWork(a, subject.task, id);
                defer child.deinit();
                const value = child.value;
                return .{
                    .execution = value.execution_revision,
                    .control = value.control_revision,
                    .realization = value.realization_revision,
                    .checkpoint = p.ObjectIdentity.from(value.checkpoint),
                    .outer = p.ObjectIdentity.optional(
                        if (value.outer_operation) |pending|
                            pending.capsule
                        else
                            value.runtime_capsule,
                    ),
                    .runtime = p.ObjectIdentity.optional(value.runtime),
                };
            }
            try retainRootOperation(self, a);
            var parent = try self.task(a, subject.task);
            defer parent.deinit();
            var saved = try rootOperation(self, a, parent.value);
            defer if (saved) |*item| item.deinit();
            return .{
                .execution = parent.value.execution_revision,
                .control = parent.value.revision,
                .realization = parent.value.realization_revision,
                .checkpoint = p.ObjectIdentity.from(parent.value.checkpoint),
                .outer = p.ObjectIdentity.optional(if (saved != null and
                    saved.?.value.pending != null) saved.?.value.pending.?.capsule else null),
                .runtime = p.ObjectIdentity.optional(parent.value.controller_runtime),
            };
        }
        pub fn placementFreeze(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("../placement.zig").Subject,
            peer_name: []const u8,
            expected: @import("../placement.zig").Cut,
            transfer: state.Digest,
        ) !@import("../placement.zig").Intent {
            // Separate controller and work subjects retain independent epochs.
            // This returns only after the source can no longer run the subject.
            const journal = @import("../placement_journal.zig");
            var parent = try self.task(a, subject.task);
            defer parent.deinit();
            try requireMovableControllerDependency(self, a, subject);
            const site = try placementSite(self);
            const peer = try placementPeer(self, peer_name);
            var prior = try journal.custody(store(self), a, subject);
            defer if (prior) |*saved| saved.deinit();
            if (prior == null and !try store(self).locallyAdmitted(subject.task))
                return error.CustodyNotLocal;
            const current =
                if (prior) |saved| saved.value else try initialCustody(self, a, subject, site);
            if (current.phase == .frozen and current.intent != null and
                std.meta.eql(current.intent.?.transfer, transfer))
            {
                const intent = current.intent.?;
                if (!std.meta.eql(intent.destination, peer.site) or
                    !std.meta.eql(intent.cut, expected))
                    return error.OperationConflict;
                return intent;
            }
            try current.requireLocal(site);
            try journal.requireSettled(store(self), a, subject, site);
            try requireSettledPlacementMoves(self, a, subject, site, transfer);
            try compatible(self, parent.value);
            if (!std.meta.eql(expected, try placementCut(self, a, subject)))
                return error.StaleRevision;
            if (self.work) |running| if (std.meta.eql(running.task, subject.task) and
                std.meta.eql(running.subject_work, subject.work)) return error.UnsettledOccurrence;
            try requireSettledPlacementDelegations(self, a, parent.value, subject);
            try requireSettledPlacementOccurrences(self, a, subject);
            const intent = try placementFreezeIntent(
                self,
                a,
                subject,
                peer,
                site,
                current,
                expected,
                transfer,
            );
            const frozen = try current.freeze(site, intent);
            try retirePlacementSubject(self, a, subject);
            try publishPlacementFreeze(self, a, parent.value, subject, site, frozen, intent);
            subjectRemove(self, .{ .task = subject.task, .work = subject.work });
            return intent;
        }
        fn retirePlacementSubject(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("../placement.zig").Subject,
        ) !void {
            // Retire before publication. If retirement fails, nothing has been
            // offered and the sole source retains its prior ownership.
            if (self.active) |active| if (std.meta.eql(active.task, subject.task) and
                ((active.subject != .work and subject.work == null) or (active.subject == .work and
                    std.meta.eql(@as(?state.Digest, active.subject.work), subject.work))))
                try retire(self, a);
        }
        fn requireSettledPlacementMoves(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("../placement.zig").Subject,
            site: @import("../placement.zig").Site,
            transfer: state.Digest,
        ) !void {
            const p = @import("../placement.zig");
            if (subject.work == null) {
                var moves = try store(self).database.prepare(
                    "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body W" ++
                        "HERE r.kind='placement_move' AND r.task=?",
                    &.{.{ .blob = &subject.task }},
                );
                defer moves.deinit();
                while (try moves.step() == .row) {
                    var moving = try contracts.decodeOwned(p.Move, a, try moves.bytes(0));
                    defer moving.deinit();
                    if (std.meta.eql(moving.value.owner, site) and moving.value.decision == null and
                        !moving.value.cancelled and !std.meta.eql(moving.value.id, transfer))
                        return error.UnsettledRemoteControl;
                }
            }
        }
        fn requireSettledPlacementDelegations(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            subject: @import("../placement.zig").Subject,
        ) !void {
            if (subject.work) |work_id| {
                const ids = try workspaceIds(self, a, subject.task);
                defer a.free(ids);
                for (ids) |id| {
                    var child = try self.workspaceWork(a, subject.task, id);
                    defer child.deinit();
                    const ref = child.value.delegation orelse continue;
                    if (child.value.terminal() and child.value.answer_value == null) continue;
                    var delegation = try contracts.decodeOwned(
                        workspace.Delegation,
                        a,
                        try store(self).object(a, ref, null),
                    );
                    defer delegation.deinit();
                    if (!std.meta.eql(work_id, child.value.id) and
                        !std.meta.eql(work_id, delegation.value.work))
                        continue;
                    if (try delegationCurrent(self, a, parent, child.value))
                        return error.UnsettledOccurrence;
                }
            }
        }
        fn requireSettledPlacementOccurrences(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("../placement.zig").Subject,
        ) !void {
            var pending_rows = try store(self).database.prepare(
                "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body W" ++
                    "HERE r.kind='occurrence' AND r.task=?",
                &.{.{ .blob = &subject.task }},
            );
            defer pending_rows.deinit();
            while (try pending_rows.step() == .row) {
                var pending =
                    try contracts.decodeOwned(occurrence.Occurrence, a, try pending_rows.bytes(0));
                defer pending.deinit();
                if (!std.meta.eql(pending.value.work, subject.work)) continue;
                if (pending.value.state == .dispatching or pending.value.state == .unknown)
                    return error.UnsettledOccurrence;
            }
        }
        fn placementFreezeIntent(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("../placement.zig").Subject,
            peer: @import("../placement.zig").Peer,
            site: @import("../placement.zig").Site,
            current: @import("../placement.zig").Custody,
            expected: @import("../placement.zig").Cut,
            transfer: state.Digest,
        ) !@import("../placement.zig").Intent {
            const p = @import("../placement.zig");
            const compatibility = try placementCompatibility(self, a, subject);
            const resources = try self.profile.resourceIdentity(a, self.application.image_identity);
            if (!std.meta.eql(compatibility, peer.compatibility) or
                !std.meta.eql(resources, peer.resource_binding)) return error.IncompatibleProfile;
            const intent: p.Intent = .{
                .transfer = transfer,
                .subject = subject,
                .source = site,
                .destination = peer.site,
                .source_native = self.profile.runtime_identity,
                .destination_native = peer.native_build,
                .epoch = current.epoch,
                .cut = expected,
                .compatibility = compatibility,
                .resources = resources,
                .disclosure = peer.disclosure_policy,
            };
            return intent;
        }
        fn publishPlacementFreeze(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            subject: @import("../placement.zig").Subject,
            site: @import("../placement.zig").Site,
            frozen: @import("../placement.zig").Custody,
            intent: @import("../placement.zig").Intent,
        ) !void {
            const journal = @import("../placement_journal.zig");
            var compiler_facts: Compiler.CompilerFacts = .{ .allocator = self.allocator };
            defer compiler_facts.deinit();
            const prior_compiler_facts = self.compiler_facts;
            if (self.compiler_facts == null) self.compiler_facts = &compiler_facts;
            defer self.compiler_facts = prior_compiler_facts;
            {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const manifest = try store(self).archiveIndex(
                    arena.allocator(),
                    subject.task,
                    compilerReference(self.assets.manifest),
                );
                try prepareCompilerFacts(self, manifest, store(self));
            }
            try store(self).begin();
            defer store(self).rollback();
            try retainPlacementDirectory(self, a, subject, site);
            try journal.putCustody(store(self), a, frozen);
            try retainPlacementSnapshot(self, a, parent, subject, frozen, intent);
            try self.namespace.commit("placement.freeze");
        }
        fn retainPlacementDirectory(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("../placement.zig").Subject,
            site: @import("../placement.zig").Site,
        ) !void {
            const p = @import("../placement.zig");
            const journal = @import("../placement_journal.zig");
            // Enabling placement on an existing local task first records its
            // complete controller/work directory. Copies of its other subjects
            // cannot inherit implicit local custody at a destination.
            var controller =
                try journal.custody(store(self), a, .{ .task = subject.task });
            defer if (controller) |*record_value| record_value.deinit();
            if (controller == null) {
                try journal.putCustody(
                    store(self),
                    a,
                    try initialCustody(self, a, .{ .task = subject.task }, site),
                );
            }
            const children = try workspaceIds(self, a, subject.task);
            defer a.free(children);
            for (children) |id| {
                var child =
                    try journal.custody(store(self), a, .{
                        .task = subject.task,
                        .work = id,
                    });
                defer if (child) |*record_value| record_value.deinit();
                if (child == null) try journal.putCustody(
                    store(self),
                    a,
                    p.Custody.initial(.{ .task = subject.task, .work = id }, site),
                );
            }
        }
        fn retainPlacementSnapshot(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            subject: @import("../placement.zig").Subject,
            frozen: @import("../placement.zig").Custody,
            intent: @import("../placement.zig").Intent,
        ) !void {
            const p = @import("../placement.zig");
            // Capture the exact export while custody and its directory are still
            // unpublished. Later sibling progress cannot change this cut.
            var snapshot_arena = std.heap.ArenaAllocator.init(a);
            defer snapshot_arena.deinit();
            const snapshot_a = snapshot_arena.allocator();
            const manifest = try archive_api.prepare(
                snapshot_a,
                store(self),
                subject.task,
                self.assets.manifest,
            );
            try validateArchiveAdmissions(self, snapshot_a, parent, manifest);
            try validateWorkspaceArchive(
                self,
                snapshot_a,
                parent,
                manifest.records.items,
                .inspect,
            );
            try archive_api.retainAssets(snapshot_a, store(self), self.assets.manifest);
            const snapshot: p.Snapshot = .{
                .id = frozen.id,
                .task = subject.task,
                .work = subject.work,
                .frozen = .{ .intent = intent, .manifest = manifest },
            };
            if (try store(self).recordBytes(
                snapshot_a,
                "placement_snapshot",
                snapshot.id,
                snapshot.task,
            )) |bytes| {
                snapshot_a.free(bytes);
                try store(self).putRecord(
                    p.Snapshot,
                    "placement_snapshot",
                    snapshot.id,
                    snapshot.task,
                    snapshot,
                );
            } else try store(self).createRecord(
                p.Snapshot,
                "placement_snapshot",
                snapshot.id,
                snapshot.task,
                snapshot,
            );
        }
        pub fn placementOffer(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("../placement.zig").Subject,
            peer_name: []const u8,
            path: []const u8,
        ) !@import("../placement.zig").Signed(@import("../placement.zig").Offer) {
            // Prepare the authenticated transport file locally. No peer sees an
            // offer until both its file and signed source record are durable.
            const journal = @import("../placement_journal.zig");
            var parent = try self.task(a, subject.task);
            defer parent.deinit();
            const peer = try placementPeer(self, peer_name);
            var saved = try journal.custody(store(self), a, subject) orelse
                return error.InvalidTransfer;
            defer saved.deinit();
            const site = try placementSite(self);
            if (saved.value.phase != .frozen or saved.value.intent == null or
                !std.meta.eql(saved.value.owner, site) or
                !std.meta.eql(saved.value.intent.?.source, site) or
                !std.meta.eql(saved.value.intent.?.destination, peer.site))
                return error.InvalidTransfer;
            try validatePlacementOfferProfile(self, a, saved.value.intent.?, peer);
            if (saved.value.offer) |prior| return replayPlacementOffer(
                self,
                a,
                subject,
                path,
                peer,
                prior,
            );
            return publishPlacementOffer(self, a, subject, path, peer, saved.value);
        }
        fn publishPlacementOffer(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("../placement.zig").Subject,
            path: []const u8,
            peer: @import("../placement.zig").Peer,
            custody: @import("../placement.zig").Custody,
        ) !@import("../placement.zig").Signed(@import("../placement.zig").Offer) {
            const p = @import("../placement.zig");
            const journal = @import("../placement_journal.zig");
            var snapshot =
                try record(self, p.Snapshot, a, "placement_snapshot", custody.id, subject.task);
            defer snapshot.deinit();
            const frozen_snapshot = snapshot.value.frozen orelse return error.InvalidTransfer;
            if (!std.meta.eql(frozen_snapshot.intent, custody.intent.?))
                return error.InvalidTransfer;
            const exported = try archive_api.writePrepared(
                self.allocator,
                self.io,
                store(self),
                frozen_snapshot.manifest,
                self.assets.manifest,
                path,
                self.namespace.directory,
            );
            var reader = try archive_api.Reader.open(a, path);
            defer reader.deinit();
            if (!std.meta.eql(reader.identity, exported.sha256) or reader.bytes != exported.bytes)
                return error.InvalidTransfer;
            if (peer.archive_limit) |limit| if (reader.bytes > limit) return error.Capacity;
            try peer.disclose(peer.context, subject, reader.manifest.value.objects.items);
            const signed = try p.sign(p.Offer, a, self.profile.placement.?.signing_key, .{
                .intent = custody.intent.?,
                .archive_digest = exported.sha256,
                .archive_bytes = exported.bytes,
            });
            const offered_value = try custody.offered(a, signed);
            try store(self).begin();
            defer store(self).rollback();
            try journal.putCustody(store(self), a, offered_value);
            try self.namespace.commit("placement.offer");
            return signed;
        }
        fn replayPlacementOffer(
            _: *Self,
            a: std.mem.Allocator,
            subject: @import("../placement.zig").Subject,
            path: []const u8,
            peer: @import("../placement.zig").Peer,
            prior: @import("../placement.zig").Signed(@import("../placement.zig").Offer),
        ) !@import("../placement.zig").Signed(@import("../placement.zig").Offer) {
            var retained = try archive_api.Reader.open(a, path);
            defer retained.deinit();
            if (!std.meta.eql(retained.identity, prior.value.archive_digest) or
                retained.bytes != prior.value.archive_bytes) return error.InvalidTransfer;
            if (peer.archive_limit) |limit| if (retained.bytes > limit) return error.Capacity;
            try peer.disclose(peer.context, subject, retained.manifest.value.objects.items);
            return prior;
        }
        fn validatePlacementOfferProfile(
            self: *Self,
            a: std.mem.Allocator,
            intent: @import("../placement.zig").Intent,
            peer: @import("../placement.zig").Peer,
        ) !void {
            if (!std.meta.eql(intent.source_native, self.profile.runtime_identity) or
                !std.meta.eql(intent.destination_native, peer.native_build) or
                !std.meta.eql(intent.compatibility, peer.compatibility) or
                !std.meta.eql(intent.resources, peer.resource_binding) or
                !std.meta.eql(
                    intent.resources,
                    try self.profile.resourceIdentity(a, self.application.image_identity),
                ) or
                !std.meta.eql(intent.disclosure, peer.disclosure_policy))
                return error.IncompatibleProfile;
        }
        pub fn placementMove(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("../placement.zig").Subject,
            peer_name: []const u8,
            expected: @import("../placement.zig").Cut,
            transfer: state.Digest,
        ) !@import("../placement.zig").Signed(@import("../placement.zig").Decision) {
            // Native convenience operation over the same bilateral protocol. All
            // interruption paths retain frozen custody until a signed decision.
            const peer = try placementPeer(self, peer_name);
            if (peer.channel == null) return error.UnsupportedCapability;
            const directory = try placementDirectory(self, a);
            if (try self.placementStatus(a, subject)) |prior| if (prior.intent) |intent| {
                if (std.meta.eql(intent.transfer, transfer)) {
                    if (!std.meta.eql(intent.cut, expected) or !std.meta.eql(
                        intent.destination,
                        peer.site,
                    )) return error.OperationConflict;
                    if (prior.decision) |decision| {
                        try retirePlacementFiles(self, a, decision);
                        return decision;
                    }
                }
            };
            _ = try placementFreeze(self, a, subject, peer_name, expected, transfer);
            const path = try std.fmt.allocPrint(a, "{s}/outgoing-{s}.par", .{
                directory,
                std.fmt.bytesToHex(transfer, .lower),
            });
            defer a.free(path);
            const offer = try placementOffer(self, a, subject, peer_name, path);
            var connection =
                try @import("../placement_transport.zig").Connection.open(a, self.io, peer);
            defer connection.deinit();
            const decision = try connection.transfer(a, offer, path);
            try placementApplyDecision(self, a, subject, decision);
            return decision;
        }
        pub fn placementApplyDecision(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("../placement.zig").Subject,
            signed: @import("../placement.zig").Signed(@import("../placement.zig").Decision),
        ) !void {
            const journal = @import("../placement_journal.zig");
            var parent = try self.task(a, subject.task);
            defer parent.deinit();
            var saved = try journal.custody(store(self), a, subject) orelse
                return error.InvalidTransfer;
            defer saved.deinit();
            const result = try saved.value.decided(a, signed);
            if (std.meta.eql(result, saved.value))
                return retirePlacementFiles(self, a, signed);
            try store(self).begin();
            defer store(self).rollback();
            try journal.putCustody(store(self), a, result);
            try self.namespace.commit("placement.decision");
            try retirePlacementFiles(self, a, signed);
            // Refusal releases custody but does not override a user's parked
            // state or implicitly select the next execution action.
        }
        pub fn placementRefuse(
            self: *Self,
            a: std.mem.Allocator,
            peer_name: []const u8,
            offered: @import("../placement.zig").Signed(@import("../placement.zig").Offer),
            reason: @import("../placement.zig").Refusal,
        ) !@import("../placement.zig").Signed(@import("../placement.zig").Decision) {
            const p = @import("../placement.zig");
            const journal = @import("../placement_journal.zig");
            try allowed(self);
            const peer = try placementPeer(self, peer_name);
            const site = try placementSite(self);
            try p.verify(p.Offer, a, offered, peer.site);
            if (!std.meta.eql(offered.value.intent.destination, site)) return error.InvalidTransfer;
            if (try journal.decision(store(self), a, offered.value.intent.transfer)) |existing| {
                var prior = existing;
                defer prior.deinit();
                try p.matchDecision(a, offered.value, prior.value);
                try retirePlacementFiles(self, a, prior.value);
                return prior.value;
            }
            const signed = try p.sign(
                p.Decision,
                a,
                self.profile.placement.?.signing_key,
                .{ .transfer = offered.value.intent.transfer, .offer_digest = try p.digest(
                    p.Offer,
                    a,
                    offered.value,
                ), .source = peer.site, .destination = site, .epoch = try std.math.add(
                    u64,
                    offered.value.intent.epoch,
                    1,
                ), .verdict = .{ .refused = reason } },
            );
            try store(self).begin();
            defer store(self).rollback();
            try journal.putDecision(store(self), a, site, offered.value, signed);
            try self.namespace.commit("placement.refused");
            try retirePlacementFiles(self, a, signed);
            return signed;
        }
    };
}
