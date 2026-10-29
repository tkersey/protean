const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const discovery = @import("../discovery.zig");
const json = @import("../json.zig");
const values = @import("../values.zig");
const archive_api = @import("../archive.zig");
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const PlacementImport = task_types.PlacementImport;
const operation = task_types.operation;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const acceptsMessages = Controller.acceptsMessages;
        const allowed = Lifecycle.allowed;
        const archiveAccess = Occurrences.archiveAccess;
        const compatible = Controller.compatible;
        const event = Records.event;
        const persist = Records.persist;
        const placementPeer = Transport.placementPeer;
        const placementSite = Lifecycle.placementSite;
        const prepareCompilerFacts = Compiler.prepareCompilerFacts;
        const receipt = Records.receipt;
        const record = Records.record;
        const recover = Recovery.recover;
        const recoverControllerResiduals = Recovery.recoverControllerResiduals;
        const replay = Records.replay;
        const retire = Lifecycle.retire;
        const retirePlacementFiles = Transport.retirePlacementFiles;
        const rootDriver = Controller.rootDriver;
        const rootOperation = Controller.rootOperation;
        const store = Lifecycle.store;
        const validateArchiveAdmissions = Occurrences.validateArchiveAdmissions;
        const validateResult = Root.validateResult;
        const validateRootOperation = Controller.validateRootOperation;
        const validateWorkspaceArchive = Snapshots.validateWorkspaceArchive;
        const workspaceIds = Recovery.workspaceIds;
        const Occurrences = @import("archive_occurrences.zig").Operations(Types, Self);
        const Compiler = @import("compiler_preparation.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const PlacementCustody = @import("placement_custody.zig").Operations(Types, Self);
        const Transport = @import("placement_transport.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Root = @import("root_execution.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Recovery = @import("work_recovery.zig").Operations(Types, Self);
        const Snapshots = @import("workspace_snapshots.zig").Operations(Types, Self);
        pub fn exportCheckpoint(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            path: []const u8,
        ) !archive_api.Exported {
            try archiveAccess(self);
            try retire(self, a);
            var compiler_facts: Compiler.CompilerFacts = .{ .allocator = self.allocator };
            defer compiler_facts.deinit();
            const prior_compiler_facts = self.compiler_facts;
            if (self.compiler_facts == null) self.compiler_facts = &compiler_facts;
            defer self.compiler_facts = prior_compiler_facts;
            _ = try store(self).auditRetention(self.handlers, self.application.image_identity);
            var value = try self.task(a, task_id);
            defer value.deinit();
            try compatible(self, value.value);
            {
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                const index = try store(self).archiveIndex(arena.allocator(), task_id, .{
                    .digest = storage.digest(self.assets.manifest),
                    .bytes = self.assets.manifest.len,
                });
                try validateArchiveAdmissions(self, arena.allocator(), value.value, index);
                try validateWorkspaceArchive(
                    self,
                    arena.allocator(),
                    value.value,
                    index.records.items,
                    .inspect,
                );
            }
            return archive_api.write(
                self.allocator,
                self.io,
                store(self),
                task_id,
                self.assets.manifest,
                path,
                self.namespace.directory,
            );
        }
        pub fn importCheckpoint(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            path: []const u8,
        ) !Admission {
            // A data-copy admission into a fresh namespace, not live custody.
            // Existing task IDs/receipts survive; current grants are never loaded
            // from the archive and no resident becomes runnable on import.
            return importCheckpointFrom(self, a, id, path, null);
        }
        pub fn placementAccept(
            self: *Self,
            a: std.mem.Allocator,
            operation_id: []const u8,
            peer_name: []const u8,
            offered: @import("../placement.zig").Signed(@import("../placement.zig").Offer),
            path: []const u8,
        ) !@import("../placement.zig").Signed(@import("../placement.zig").Decision) {
            const p = @import("../placement.zig");
            const journal = @import("../placement_journal.zig");
            try allowed(self);
            const peer = try placementPeer(self, peer_name);
            const site = try placementSite(self);
            const intent = offered.value.intent;
            try p.verify(p.Offer, a, offered, peer.site);
            if (!std.meta.eql(intent.destination, site)) return error.InvalidTransfer;
            if (try journal.decision(store(self), a, intent.transfer)) |existing| {
                var prior = existing;
                defer prior.deinit();
                try p.matchDecision(a, offered.value, prior.value);
                try retirePlacementFiles(self, a, prior.value);
                return prior.value;
            }
            if (!std.meta.eql(intent.destination_native, self.profile.runtime_identity) or
                !std.meta.eql(intent.source_native, peer.native_build) or
                !std.meta.eql(intent.compatibility, peer.compatibility) or
                !std.meta.eql(intent.resources, peer.resource_binding) or
                !std.meta.eql(
                    intent.resources,
                    try self.profile.resourceIdentity(a, self.application.image_identity),
                ) or
                !std.meta.eql(intent.disclosure, peer.disclosure_policy))
                return error.IncompatibleProfile;
            const signed = try p.sign(p.Decision, a, self.profile.placement.?.signing_key, .{
                .transfer = intent.transfer,
                .offer_digest = try p.digest(p.Offer, a, offered.value),
                .source = peer.site,
                .destination = site,
                .epoch = try std.math.add(u64, intent.epoch, 1),
                .verdict = .accepted,
            });
            _ = try importCheckpointFrom(self, a, operation_id, path, .{
                .offer = offered,
                .decision = signed,
                .peer = peer,
            });
            try retirePlacementFiles(self, a, signed);
            return signed;
        }
        fn importCheckpointFrom(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            path: []const u8,
            placement: ?PlacementImport,
        ) !Admission {
            try archiveAccess(self);
            var reader = try archive_api.Reader.open(self.allocator, path);
            defer reader.deinit();
            const request = try importCheckpointRequest(self, a, &reader, placement);
            if (try replay(self, a, id, request)) |prior| return prior;
            try requireImportNamespace(self, a, placement);
            var compiler_facts: Compiler.CompilerFacts = .{ .allocator = self.allocator };
            defer compiler_facts.deinit();
            const prior_compiler_facts = self.compiler_facts;
            if (self.compiler_facts == null) self.compiler_facts = &compiler_facts;
            defer self.compiler_facts = prior_compiler_facts;
            try prepareCompilerFacts(self, reader.manifest.value, &reader);
            try store(self).begin();
            defer store(self).rollback();
            try reader.acquire(store(self));
            var inspected = inspected: {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const result = try archive_api.inspect(
                    arena.allocator(),
                    store(self),
                    reader.manifest.value,
                    null,
                );
                break :inspected .{ .task = result.task, .current = result.current };
            };
            defer inspected.task.deinit();
            var value = inspected.task.value;
            const original_runtime = value.runtime_identity;
            try validateImportedProfile(self, &value);
            try validateImportedBuild(self, a, reader.manifest.value.build);
            try validateImportedArchive(self, a, value, reader.manifest.value);
            try validateImportedState(self, a, value, inspected.current);
            const accepted_custody =
                try acceptImportedCustody(self, a, value, original_runtime, placement);
            try retireImportedCustody(self, a, value.id, reader.manifest.value.records.items);
            try publishImportedCustody(self, a, &value, placement, accepted_custody);
            return publishCheckpointImport(
                self,
                a,
                id,
                request,
                value,
                original_runtime,
                reader.identity,
                reader.manifest.value.build,
                placement,
            );
        }
        fn validateImportedArchive(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            manifest: state.Archive,
        ) !void {
            // Restore only inside the unpublished transaction, then admit the
            // original operation identities and all related input history.
            try store(self).restoreArchiveIndex(a, manifest, value);
            try validateArchiveAdmissions(self, a, value, manifest);
            try validateWorkspaceArchive(self, a, value, manifest.records.items, .retain);
            // This transaction contains untrusted, unpublished archive data.
            // Reuse the closure validator without treating semantic rejection
            // as corruption of the committed namespace. Store integrity and
            // rollback failures retain their own fencing behavior.
            _ = try @import("../retention.zig").verify(store(self), self.handlers);
        }
        fn requireImportNamespace(
            self: *Self,
            _: std.mem.Allocator,
            placement: ?PlacementImport,
        ) !void {
            if ((placement == null and store(self).head.generation != 0) or
                self.active != null or self.runnable.items.len != 0)
                return error.NonEmptyNamespace;
            var tasks_present =
                try store(self).database.prepare("SELECT 1 FROM tasks LIMIT 1", &.{});
            defer tasks_present.deinit();
            if (try tasks_present.step() == .row) return error.NonEmptyNamespace;
        }
        fn importCheckpointRequest(
            _: *Self,
            a: std.mem.Allocator,
            reader: *archive_api.Reader,
            placement: ?PlacementImport,
        ) !state.Digest {
            return if (placement) |transfer| blk: {
                if (!std.meta.eql(reader.identity, transfer.offer.value.archive_digest) or
                    reader.bytes != transfer.offer.value.archive_bytes)
                    return error.InvalidTransfer;
                if (transfer.peer.archive_limit) |limit| if (reader.bytes > limit)
                    return error.Capacity;
                try transfer.peer.disclose(
                    transfer.peer.context,
                    transfer.offer.value.intent.subject,
                    reader.manifest.value.objects.items,
                );
                const Request = struct {
                    method: state.Method,
                    archive: state.Digest,
                    transfer: state.Digest,
                };
                break :blk try operation(Request, a, .{
                    .method = .import_checkpoint,
                    .archive = reader.identity,
                    .transfer = transfer.offer.value.intent.transfer,
                });
            } else blk: {
                const Request = struct { method: state.Method, archive: state.Digest };
                break :blk try operation(Request, a, .{
                    .method = .import_checkpoint,
                    .archive = reader.identity,
                });
            };
        }
        fn validateImportedProfile(self: *Self, value: *state.Task) !void {
            if (!same(value.*.principal.bytes, self.profile.authority.principal) or
                !same(value.*.tenant.bytes, self.profile.authority.tenant)) return error.Denied;
            value.*.runtime_identity = self.profile.runtime_identity;
            value.*.schedule = .parked;
            try compatible(self, value.*);
            if (!same(value.*.input_schema_id.bytes, Types.input_schema_id) or
                !same(value.*.output_schema_id.bytes, Types.output_schema_id) or
                !same(value.*.failure_schema_id.bytes, Types.failure_schema_id) or
                !same(value.*.message_schema_id.bytes, Types.message_schema_id))
                return error.IncompatibleProfile;
        }
        fn validateImportedBuild(
            self: *Self,
            a: std.mem.Allocator,
            reference: state.Reference,
        ) !void {
            const build_bytes = try store(self).object(a, reference, null);
            defer a.free(build_bytes);
            var build = try json.parseAsset(a, build_bytes, build_bytes.len);
            defer build.deinit();
            for ([_][]const u8{
                "native_host_contract",
                "protocol",
                "client_mapping",
                "state_format",
                "program_sha256",
                "program_identity",
                "application_assets_sha256",
                "optimize",
            }) |field| {
                const expected =
                    json.get(self.application.manifest, field) orelse return error.InvalidAssets;
                try discovery.sameField(build.value, field, try json.text(expected));
            }
            const dependencies =
                json.get(build.value, "dependencies") orelse return error.InvalidArchive;
            const current_dependencies = json.get(self.application.manifest, "dependencies") orelse
                return error.InvalidAssets;
            for ([_][]const u8{ "world", "boundary" }) |field| try discovery.sameField(
                dependencies,
                field,
                try json.text(json.get(current_dependencies, field) orelse
                    return error.InvalidAssets),
            );
            const compiler = json.get(build.value, "compiler") orelse return error.InvalidArchive;
            const current_compiler =
                json.get(self.application.manifest, "compiler") orelse return error.InvalidAssets;
            try discovery.sameField(
                compiler,
                "version",
                try json.text(json.get(current_compiler, "version") orelse
                    return error.InvalidAssets),
            );
        }
        fn acceptImportedCustody(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            original_runtime: state.Digest,
            placement: ?PlacementImport,
        ) !?@import("../placement.zig").Custody {
            return if (placement) |transfer| accepted: {
                const p = @import("../placement.zig");
                const intent = transfer.offer.value.intent;
                if (!std.meta.eql(value.id, intent.subject.task) or
                    !std.meta.eql(original_runtime, intent.source_native) or
                    !std.meta.eql(try self.placementCut(a, intent.subject), intent.cut) or
                    !std.meta.eql(
                        try self.placementCompatibility(a, intent.subject),
                        intent.compatibility,
                    )) return error.InvalidTransfer;
                var frozen = try @import("../placement_journal.zig").custody(
                    store(self),
                    a,
                    intent.subject,
                ) orelse return error.InvalidTransfer;
                defer frozen.deinit();
                break :accepted try p.accept(
                    a,
                    try placementSite(self),
                    frozen.value,
                    transfer.offer,
                    transfer.decision,
                );
            } else null;
        }
        fn retireImportedCustody(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            records: []const state.ArchiveRecord,
        ) !void {
            for (records) |row| if (row.kind == .placement_custody) {
                var copied = try record(
                    self,
                    @import("../placement.zig").Custody,
                    a,
                    "placement_custody",
                    row.id,
                    task_id,
                );
                defer copied.deinit();
                if (copied.value.phase != .away) {
                    copied.value.phase = .away;
                    try @import("../placement_journal.zig").putCustody(
                        store(self),
                        a,
                        copied.value,
                    );
                }
            };
        }
        fn publishImportedCustody(
            self: *Self,
            a: std.mem.Allocator,
            value: *state.Task,
            placement: ?PlacementImport,
            accepted_custody: ?@import("../placement.zig").Custody,
        ) !void {
            if (placement) |transfer| {
                const p = @import("../placement.zig");
                const journal = @import("../placement_journal.zig");
                const intent = transfer.offer.value.intent;
                // Copied controller/work data grants no custody over another
                // subject. Legacy unregistered subjects stay at the source.
                const others = try workspaceIds(self, a, value.*.id);
                defer a.free(others);
                for (others) |work_id| if (!std.meta.eql(
                    intent.subject.work,
                    @as(?state.Digest, work_id),
                )) {
                    var prior = try journal.custody(store(self), a, .{
                        .task = value.*.id,
                        .work = work_id,
                    });
                    defer if (prior) |*record_value| record_value.deinit();
                    if (prior == null) try journal.putCustody(
                        store(self),
                        a,
                        p.Custody.initial(.{ .task = value.*.id, .work = work_id }, intent.source),
                    );
                };
                if (intent.subject.work != null) {
                    var prior =
                        try journal.custody(store(self), a, .{ .task = value.*.id });
                    defer if (prior) |*record_value| record_value.deinit();
                    if (prior == null) {
                        var controller = p.Custody.initial(.{ .task = value.*.id }, intent.source);
                        controller.epoch = value.*.controller_epoch;
                        try journal.putCustody(store(self), a, controller);
                    }
                }
                try retire(self, a);
                try journal.putCustody(store(self), a, accepted_custody.?);
                if (intent.subject.work == null) {
                    if (value.*.controller_succession != null or
                        value.*.controller_epoch != intent.epoch)
                        return error.InvalidTransfer;
                    value.*.controller_epoch = accepted_custody.?.epoch;
                }
                try journal.putDecision(
                    store(self),
                    a,
                    try placementSite(self),
                    transfer.offer.value,
                    transfer.decision,
                );
            }
        }
        fn publishCheckpointImport(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            request: state.Digest,
            imported: state.Task,
            original_runtime: state.Digest,
            archive_identity: state.Digest,
            build_reference: state.Reference,
            placement: ?PlacementImport,
        ) !Admission {
            var value = imported;
            const previous = value.revision;
            value.revision = try std.math.add(u64, previous, 1);
            const origin: state.Origin = .{
                .id = archive_identity,
                .task = value.id,
                .build = build_reference,
                .native_identity = original_runtime,
                .source_revision = previous,
                .transfer = if (placement) |transfer|
                    transfer.offer.value.intent.transfer
                else
                    null,
            };
            try store(self).createRecord(state.Origin, "origin", origin.id, value.id, origin);
            var event_data = json.object();
            try json.put(
                a,
                &event_data,
                "archive_sha256",
                json.string(try a.dupe(u8, &std.fmt.bytesToHex(archive_identity, .lower))),
            );
            try event(self, &value, .imported, try json.canonical(a, event_data));
            const admitted =
                try receipt(self, a, .import_checkpoint, id, request, value, .imported, null, null);
            try persist(self, a, value, previous, "checkpoint.import", .preserve);
            // Imported pending lookups have no live worker in this owner.
            // A crash before this ordinary transition is handled on reopen.
            try recover(self, a, value.id);
            try recoverControllerResiduals(self, a, value.id);
            return admitted;
        }
        fn validatePendingMessages(self: *Self, a: std.mem.Allocator, value: state.Task) !void {
            // Ordering and byte bounds belong to the pending projection. Complete
            // typed payload/receipt/occurrence coherence is checked for all history
            // by validateArchiveAdmissions and validateOccurrenceProvenance.
            if (value.messages.items.len != 0 and (value.terminal() or !acceptsMessages(self)))
                return error.InvalidArchive;
            var previous: u64 = 0;
            for (value.messages.items, 0..) |id, index| {
                var decoded = try record(self, state.Message, a, "message", id, value.id);
                defer decoded.deinit();
                const item = decoded.value;
                if (item.ordinal <= previous) return error.InvalidArchive;
                previous = item.ordinal;
                if (item.disposition == .acquired and index != 0) return error.InvalidArchive;
            }
        }
        pub fn validateCancellation(
            a: std.mem.Allocator,
            value: anytype,
            outcome: data.invocation.Outcome,
            checkpoint: []const u8,
        ) !void {
            // Bind native intent to the actual kernel cancellation, for roots and
            // children alike. A repeated cancel preserves any existing reason and
            // therefore cannot establish this agreement.
            if (value.cancellation_applied and value.cancellation == null)
                return error.InvalidArchive;
            var graph: ?data.state_image.Owned = null;
            defer if (graph) |*decoded| decoded.deinit();
            const actual: ?data.invocation.Reason = switch (outcome) {
                .cancelled => |cancelled| cancelled.reason,
                .failed => |failure| failure.cancellation,
                .completed => null,
                else => blk: {
                    // The matching program has already admitted this checkpoint.
                    // Read its public graph without advancing authored cleanup.
                    graph = try data.state_image.decodeGraph(a, checkpoint);
                    var cursor = graph.?.state.roots.exit orelse break :blk null;
                    const nodes = graph.?.state.nodes;
                    for (0..nodes.len) |_| {
                        if (cursor.id >= nodes.len) return error.InvalidArchive;
                        const node = nodes[@intCast(cursor.id)].record;
                        if (node != .exit) return error.InvalidArchive;
                        if (node.exit.outer) |outer| {
                            cursor = outer;
                        } else break :blk node.exit.cancellation;
                    }
                    return error.InvalidArchive;
                },
            };
            if (value.cancellation_applied != (actual != null)) return error.InvalidArchive;
            if (actual) |reason| {
                const intent = value.cancellation orelse return error.InvalidArchive;
                if (reason != .text or !same(reason.text, intent.bytes))
                    return error.InvalidArchive;
            }
        }
        fn validateImportedState(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            pending: ?occurrence.Occurrence,
        ) !void {
            if (value.cancellation_applied and value.cancellation == null)
                return error.InvalidArchive;
            try validatePendingMessages(self, a, value);
            var saved_operation = try rootOperation(self, a, value);
            defer if (saved_operation) |*saved| saved.deinit();
            if (saved_operation) |saved| _ =
                try validateRootOperation(self, a, value, saved.value);
            const driver = restored: {
                // Restore owns its admitted input. Release the serialized copy
                // before reconstruction, even when the caller uses an arena.
                const guest_checkpoint =
                    try store(self).object(self.allocator, value.checkpoint, null);
                defer self.allocator.free(guest_checkpoint);
                break :restored try rootDriver(self, a, value, .{ .state = guest_checkpoint });
            };
            var driver_live = true;
            defer if (driver_live) {
                driver.retire() catch store(self).fence();
                driver.destroy() catch store(self).fence();
            };
            const publication = try driver.drive(a, .none, 0);
            const observed = publication.outcome;
            defer a.free(observed);
            const prior = try store(self).object(a, value.outcome, null);
            defer a.free(prior);
            if (!same(observed, prior)) return error.InvalidArchive;
            const checkpoint = publication.checkpoint;
            if (!same(&storage.digest(checkpoint), &value.checkpoint.digest) or
                checkpoint.len != value.checkpoint.bytes) return error.InvalidArchive;
            var decoded = try data.invocation.decode(data.invocation.Outcome, a, observed);
            defer decoded.deinit();
            if (!same(@tagName(decoded.value), @tagName(value.outcome_kind)))
                return error.InvalidArchive;
            try validateCancellation(a, value, decoded.value, checkpoint);
            // All guest/cut checks are complete. Result mapping consumes the
            // separately owned outcome, so it need not overlap the evaluator.
            try driver.retire();
            try driver.destroy();
            driver_live = false;
            try validateImportedOutcome(self, a, value, pending, decoded.value);
        }
        fn validateImportedOutcome(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            pending: ?occurrence.Occurrence,
            outcome: data.invocation.Outcome,
        ) !void {
            switch (outcome) {
                .requested => |requested| {
                    const current = pending orelse return error.InvalidArchive;
                    var request =
                        try data.invocation.decode(data.invocation.Request, a, requested.request);
                    defer request.deinit();
                    if (!same(&current.request, &request.value.request_identity))
                        return error.InvalidArchive;
                    if (requested.request.len != current.request_object.bytes or !same(
                        &storage.digest(requested.request),
                        &current.request_object.digest,
                    )) return error.InvalidArchive;
                },
                .completed => |bytes| {
                    if (value.result == null or !same(
                        &value.result.?.digest,
                        &storage.digest(bytes),
                    )) return error.InvalidArchive;
                    try validateImportedResult(self, Types.Output, a, value, bytes);
                },
                .failed => |failure| {
                    if (value.result == null or !same(
                        &value.result.?.digest,
                        &value.outcome.digest,
                    )) return error.InvalidArchive;
                    try validateImportedResult(self, Types.Failure, a, value, failure.value);
                },
                .cancelled => {
                    if (value.result == null or
                        !same(&value.result.?.digest, &value.outcome.digest) or
                        value.client_result != null or
                        value.result_artifact != null)
                        return error.InvalidArchive;
                },
                else => {},
            }
            if (!value.terminal() and (value.result != null or value.client_result != null or
                value.result_artifact != null))
                return error.InvalidArchive;
        }
        fn validateImportedResult(
            self: *Self,
            comptime T: type,
            a: std.mem.Allocator,
            value: state.Task,
            bytes: []const u8,
        ) !void {
            var decoded = try contracts.decodeOwned(T, a, bytes);
            defer decoded.deinit();
            try validateResult(self, T, a, value, decoded.value);
            const expected = try json.canonicalBounded(
                self.allocator,
                try values.toJson(T, a, decoded.value),
                try store(self).database.blobLimit(),
            );
            defer self.allocator.free(expected);
            const reference = value.client_result orelse return error.InvalidArchive;
            if (reference.bytes != expected.len or
                !same(&reference.digest, &storage.digest(expected))) return error.InvalidArchive;
            // Verify all stored bytes without retaining a second large value.
            try store(self).objectRange(reference, 0, &.{});
            if (value.result_artifact) |id| {
                var artifact =
                    try record(self, state.Artifact, a, "artifact", id, value.id);
                defer artifact.deinit();
                if (!same(&artifact.value.value.digest, &reference.digest) or
                    artifact.value.value.bytes != reference.bytes) return error.InvalidArchive;
                const schema_id = artifact.value.schema_id orelse return error.InvalidArchive;
                if (!same(artifact.value.media_type.bytes, "application/json") or !same(
                    schema_id.bytes,
                    if (value.outcome_kind ==
                        .completed) value.output_schema_id.bytes else value.failure_schema_id.bytes,
                )) return error.InvalidArchive;
            } else if (expected.len > (@import("../protocol.zig").Limits{}).inline_bytes)
                return error.InvalidArchive;
        }
    };
}
