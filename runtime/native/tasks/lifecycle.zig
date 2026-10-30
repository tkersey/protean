const std = @import("std");
const state = @import("../state.zig");
const storage = @import("../store.zig");
const Namespace = @import("../namespace.zig").Namespace;
const evaluator = @import("../driver.zig");
const kosmos = @import("kosmos");
const registry = @import("../registry.zig");
const discovery = @import("../discovery.zig");
const task_types = @import("types.zig");
const Profile = task_types.Profile;
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Transport = @import("placement_transport.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Recovery = @import("work_recovery.zig").Operations(Types, Self);
        const compatible = Controller.compatible;
        const controllerRuntime = Controller.controllerRuntime;
        const event = Records.event;
        const persist = Records.persist;
        const recover = Recovery.recover;
        const recoverControllerResiduals = Recovery.recoverControllerResiduals;
        const recoverPlacementFiles = Transport.recoverPlacementFiles;
        const recoverWorkspace = Recovery.recoverWorkspace;
        const retainRootOperation = Controller.retainRootOperation;
        const rootDriver = Controller.rootDriver;
        const rootImage = Controller.rootImage;
        const rootOperation = Controller.rootOperation;
        const rootProvenance = Controller.rootProvenance;
        const task = Tasks.task;
        const validateRootOperation = Controller.validateRootOperation;
        pub fn init(
            a: std.mem.Allocator,
            io: std.Io,
            namespace: *Namespace,
            assets: discovery.Assets,
            application: *const discovery.Application,
            handlers: registry.Registry,
            profile: Profile,
        ) !Self {
            try profile.validate();
            var self: Self = .{
                .allocator = a,
                .io = io,
                .namespace = namespace,
                .assets = assets,
                .application = application,
                .handlers = handlers,
                .profile = profile,
                .program = try evaluator.Program.open(a, assets.image),
            };
            errdefer self.program.close() catch |err| {
                std.log.err("unpublished program cleanup failed: {s}", .{@errorName(err)});
            };
            try io.randomSecure(&self.owner_epoch);
            _ = try store(&self).auditRetention(handlers, application.image_identity);
            try recover(&self, a, null);
            try recoverWorkspace(&self, a);
            try recoverControllerResiduals(&self, a, null);
            try recoverPlacementFiles(&self, a);
            return self;
        }
        pub fn store(self: *Self) *storage.Store {
            return &self.namespace.store;
        }
        pub fn allowed(self: *Self) !void {
            if (self.profile.authority.revoked or !self.profile.authority.disclosure)
                return error.Denied;
            if (store(self).fenced) return error.StorageUnavailable;
        }
        pub fn placementSite(self: *Self) !@import("../placement.zig").Site {
            const configured = self.profile.placement orelse return error.UnsupportedCapability;
            return .{
                .key = configured.signing_key.public_key.toBytes(),
                .namespace = self.namespace.identity,
            };
        }
        pub fn requireCustody(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            work_id: ?state.Digest,
        ) !void {
            // Historical validation may project an existing receipt, but its
            // replay guard forbids executing a missing operation.
            if (self.workspace_replay != null) return;
            if (try @import("../placement_journal.zig").custody(
                store(self),
                a,
                .{ .task = task_id, .work = work_id },
            )) |saved| {
                var current = saved;
                defer current.deinit();
                if (self.profile.placement == null) return error.CustodyNotLocal;
                try current.value.requireLocal(try placementSite(self));
            } else if (!try store(self).locallyAdmitted(task_id)) {
                return error.CustodyNotLocal;
            }
        }
        pub fn hasLocalCustody(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            work_id: ?state.Digest,
        ) !bool {
            requireCustody(self, a, task_id, work_id) catch |err| {
                if (err == error.CustodyNotLocal) return false;
                return err;
            };
            return true;
        }
        pub fn hasFrozenCustody(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            work_id: ?state.Digest,
        ) !bool {
            if (self.profile.placement == null) return false;
            var saved = try @import("../placement_journal.zig").custody(store(self), a, .{
                .task = task_id,
                .work = work_id,
            }) orelse return false;
            defer saved.deinit();
            return saved.value.phase == .frozen and std.meta.eql(
                saved.value.owner,
                try placementSite(self),
            );
        }
        pub fn createCustody(
            self: *Self,
            a: std.mem.Allocator,
            task_id: state.TaskId,
            work_id: ?state.Digest,
        ) !void {
            if (self.profile.placement == null) return;
            const custody = try initialCustody(
                self,
                a,
                .{ .task = task_id, .work = work_id },
                try placementSite(self),
            );
            try @import("../placement_journal.zig").putCustody(store(self), a, custody);
        }
        pub fn initialCustody(
            self: *Self,
            a: std.mem.Allocator,
            subject: @import("../placement.zig").Subject,
            site: @import("../placement.zig").Site,
        ) !@import("../placement.zig").Custody {
            const p = @import("../placement.zig");
            var custody = p.Custody.initial(subject, site);
            if (subject.work == null) {
                var parent = try task(self, a, subject.task);
                defer parent.deinit();
                custody.epoch = parent.value.controller_epoch;
            }
            return custody;
        }
        pub fn retire(self: *Self, a: std.mem.Allocator) !void {
            try retainRootOperation(self, a);
            if (self.active) |active| {
                try active.driver.retire();
                try active.driver.destroy();
                if (active.root_control) |bytes| self.allocator.free(bytes);
                self.active = null;
            }
        }
        pub fn resident(self: *Self, a: std.mem.Allocator, value: state.Task) !*evaluator.Driver {
            try compatible(self, value);
            if (self.active) |active| {
                if (active.subject == .root and same(&active.task, &value.id) and
                    active.execution_revision == value.execution_revision and
                    active.realization_revision == value.realization_revision)
                    return active.driver;
                try retire(self, a);
            }
            var pending = try rootOperation(self, a, value);
            defer if (pending) |*saved| saved.deinit();
            const root_control =
                if (pending != null and pending.?.value.pending != null) try store(self).object(
                    self.allocator,
                    pending.?.value.pending.?.control,
                    null,
                ) else null;
            errdefer if (root_control) |bytes| self.allocator.free(bytes);
            var root_cut_ready = false;
            const driver = if (pending != null and pending.?.value.pending != null) restored: {
                const operation_value = pending.?.value.pending.?;
                root_cut_ready = try validateRootOperation(self, a, value, pending.?.value);
                const bytes = try store(self).object(a, operation_value.capsule, null);
                defer a.free(bytes);
                const Owner = struct {
                    task: state.Task,
                    reference: state.Reference,
                    fn claim(
                        context: *anyopaque,
                        ref: kosmos.RuntimeCapsule.Reference,
                        record_value: kosmos.RuntimeCapsule.Record,
                        _: kosmos.RuntimeCapsule.Reference,
                    ) !void {
                        const owner: *@This() = @ptrCast(@alignCast(context));
                        if (!std.meta.eql(
                            ref.digest,
                            owner.reference.digest,
                        ) or ref.bytes != owner.reference.bytes or
                            !std.meta.eql(
                                record_value.provenance,
                                rootProvenance(owner.task),
                            )) return error.InvalidArchive;
                    }
                };
                var owner: Owner = .{ .task = value, .reference = operation_value.capsule };
                var runtime = try controllerRuntime(
                    self,
                    a,
                    value.id,
                    try rootImage(self, a, value),
                    value.controller_runtime,
                );
                defer runtime.deinit();
                const image =
                    try store(self).object(a, try rootImage(self, a, value), null);
                defer a.free(image);
                break :restored try evaluator.Driver.openCapsule(
                    self.allocator,
                    image,
                    &runtime,
                    bytes,
                    .{ .context = &owner, .claim = Owner.claim },
                );
            } else restored: {
                const checkpoint = try store(self).object(a, value.checkpoint, null);
                defer a.free(checkpoint);
                break :restored try rootDriver(self, a, value, .{ .state = checkpoint });
            };
            self.active = .{
                .task = value.id,
                .execution_revision = value.execution_revision,
                .realization_revision = value.realization_revision,
                .driver = driver,
                .root_control = root_control,
                .root_cut_ready = root_cut_ready,
            };
            if (pending) |saved| if (saved.value.pending) |operation_value| {
                self.active.?.root_quantum = operation_value.guest_quantum;
                self.active.?.outer_operation = operation_value.capsule;
            };
            return driver;
        }
        pub fn close(self: *Self, a: std.mem.Allocator) !void {
            if (self.work != null) return error.Busy;
            if (self.placement_job) |job| {
                job.job.deinit();
                self.placement_job = null;
            }
            try retire(self, a);
            try self.program.close();
            self.runnable.deinit(self.allocator);
            self.placement_pending.deinit(self.allocator);
            self.owned.deinit(self.allocator);
            self.checked_workspace_programs.deinit(self.allocator);
            self.checked_workspace_runtimes.deinit(self.allocator);
            if (self.runtime_cache) |*cached| cached.artifact.deinit();
            self.* = undefined;
        }
        pub fn park(self: *Self, a: std.mem.Allocator) !void {
            if (self.work != null) return error.Busy;
            if (self.placement_job) |job| {
                job.job.deinit();
                self.placement_job = null;
            }
            self.placement_pending.clearRetainingCapacity();
            for (self.owned.items) |id| {
                // Host suspension drops volatile ownership, not the child's
                // admitted scheduling intent. Explicit task resume restores
                // eligible children; a controller work.park remains durable.
                if (!try hasLocalCustody(self, a, id, null) and
                    !try hasFrozenCustody(self, a, id, null))
                    continue;
                var decoded = try task(self, a, id);
                defer decoded.deinit();
                var value = decoded.value;
                if (value.terminal() or value.schedule == .parked) continue;
                const previous = value.revision;
                value.revision = try std.math.add(u64, previous, 1);
                value.schedule = .parked;
                try store(self).begin();
                defer store(self).rollback();
                try event(self, &value, .parked, "{}");
                try persist(self, a, value, previous, "task.park", .preserve);
            }
            self.runnable.clearRetainingCapacity();
            self.runnable_cursor = 0;
            try retire(self, a);
        }
    };
}
