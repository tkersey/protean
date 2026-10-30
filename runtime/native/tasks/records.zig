const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const storage = @import("../store.zig");
const json = @import("../json.zig");
const workspace = @import("../workspace_state.zig");
const task_types = @import("types.zig");
const Admission = task_types.Admission;
const Ownership = task_types.Ownership;
const name = task_types.name;
const operation = task_types.operation;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const allowed = Lifecycle.allowed;
        const claim = Scheduling.claim;
        const ensureOwnershipCapacity = Scheduling.ensureOwnershipCapacity;
        const store = Lifecycle.store;
        const subjectAddAssumeCapacity = Scheduling.subjectAddAssumeCapacity;
        const workspaceWaitWakeups = Waits.workspaceWaitWakeups;
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);
        const Tasks = @import("task_queries.zig").Operations(Types, Self);
        const Waits = @import("workspace_waits.zig").Operations(Types, Self);
        pub fn record(
            self: *Self,
            comptime T: type,
            a: std.mem.Allocator,
            comptime kind: []const u8,
            id: state.Digest,
            task_id: state.TaskId,
        ) !contracts.Decoded(T) {
            if (T != storage.Record(kind)) @compileError("native record type/kind mismatch");
            const bytes = (try store(self).recordBytes(a, kind, id, task_id)) orelse
                return error.CorruptState;
            defer a.free(bytes);
            return contracts.decodeOwned(T, a, bytes);
        }
        pub fn replay(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            request: state.Digest,
        ) !?Admission {
            try allowed(self);
            _ = try name(id);
            const key = try operationKey(self, a, id);
            const bytes = (try store(self).receipt(a, &key, request)) orelse {
                if (self.workspace_replay != null) return error.InvalidArchive;
                return null;
            };
            defer a.free(bytes);
            var decoded = try contracts.decodeOwned(state.Receipt, a, bytes);
            defer decoded.deinit();
            var bound_task = try self.task(a, decoded.value.task);
            defer bound_task.deinit();
            var saved = decoded.value;
            saved.client_operation_id = .{
                .bytes = try a.dupe(u8, saved.client_operation_id.bytes),
            };
            if (self.workspace_replay != null and saved.method != .workspace)
                return error.InvalidArchive;
            return .{
                .receipt = saved,
                .replayed = if (self.workspace_replay) |replay_only| replay_only.replayed else true,
            };
        }
        pub fn operationKey(self: *Self, a: std.mem.Allocator, id: []const u8) ![64]u8 {
            const Key = struct {
                principal: state.Name,
                tenant: state.Name,
                operation_id: state.Name,
            };
            return std.fmt.bytesToHex(
                try operation(Key, a, .{
                    .principal = try name(self.profile.authority.principal),
                    .tenant = try name(self.profile.authority.tenant),
                    .operation_id = try name(id),
                }),
                .lower,
            );
        }
        pub fn receipt(
            self: *Self,
            a: std.mem.Allocator,
            method: state.Method,
            id: []const u8,
            request: state.Digest,
            task_value: state.Task,
            disposition: state.Disposition,
            message_id: ?state.Digest,
            question: ?state.Digest,
        ) !Admission {
            return recoveryReceipt(
                self,
                a,
                method,
                id,
                request,
                task_value,
                disposition,
                message_id,
                question,
                null,
            );
        }
        pub fn recoveryReceipt(
            self: *Self,
            a: std.mem.Allocator,
            method: state.Method,
            id: []const u8,
            request: state.Digest,
            task_value: state.Task,
            disposition: state.Disposition,
            message_id: ?state.Digest,
            question: ?state.Digest,
            reconciliation_id: ?state.Digest,
        ) !Admission {
            var identity: state.Digest = undefined;
            try self.io.randomSecure(&identity);
            const saved: state.Receipt = .{
                .id = identity,
                .client_operation_id = try name(id),
                .method = method,
                .request_digest = request,
                .task = task_value.id,
                .revision = task_value.revision,
                .disposition = disposition,
                .message = message_id,
                .question = question,
                .reconciliation = reconciliation_id,
            };
            const bytes = try contracts.encodeOwned(state.Receipt, a, saved);
            defer a.free(bytes);
            const key = try operationKey(self, a, id);
            try store(self).putReceipt(&key, request, bytes);
            return .{ .receipt = saved, .replayed = false };
        }
        pub fn event(
            self: *Self,
            value: *state.Task,
            kind: state.EventType,
            bytes: []const u8,
        ) !void {
            return publicationEvent(self, value, kind, bytes, &.{}, null);
        }
        pub fn publicationEvent(
            self: *Self,
            value: *state.Task,
            kind: state.EventType,
            bytes: []const u8,
            publications: []const state.WorkPublication,
            command: ?state.Reference,
        ) !void {
            return subjectPublicationEvent(
                self,
                value,
                kind,
                bytes,
                publications,
                &.{},
                command,
                null,
                null,
            );
        }
        pub fn subjectPublicationEvent(
            self: *Self,
            value: *state.Task,
            kind: state.EventType,
            bytes: []const u8,
            publications: []const state.WorkPublication,
            residuals: []const state.ResidualPublication,
            command: ?state.Reference,
            controller_read: ?state.ControllerReadCut,
            root_publication: ?state.RootPublication,
        ) !void {
            value.event_high = try std.math.add(u64, value.event_high, 1);
            try store(self).putEvent(.{
                .task = value.id,
                .seq = value.event_high,
                .revision = value.revision,
                .kind = kind,
                .data = .{ .bytes = bytes },
                .workspace_publications = .{ .items = publications },
                .workspace_command = command,
                .residual_publications = .{ .items = residuals },
                .controller_read = controller_read,
                .root_publication = root_publication,
            });
        }
        pub fn messageEvent(
            self: *Self,
            a: std.mem.Allocator,
            value: *state.Task,
            kind: state.EventType,
            item: state.Message,
        ) !void {
            const body = try state.messageData(a, item, item.disposition);
            const bytes = try json.canonical(a, body);
            defer a.free(bytes);
            try event(self, value, kind, bytes);
        }
        pub fn persist(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            previous: u64,
            transition: []const u8,
            ownership: Ownership,
        ) !void {
            return persistScheduled(self, a, value, previous, transition, ownership, &.{});
        }
        pub fn persistScheduled(
            self: *Self,
            a: std.mem.Allocator,
            value: state.Task,
            previous: u64,
            transition: []const u8,
            ownership: Ownership,
            scheduled: []const workspace.Subject,
        ) !void {
            var successor = value;
            // Eligibility is derived from the transaction's complete successor.
            // Reserve before commit: an acknowledged event cannot lose its
            // wake-up to allocation failure, or require each producer to notify.
            var wake: std.ArrayList(workspace.Subject) = .empty;
            defer wake.deinit(a);
            try workspaceWaitWakeups(self, a, &successor, ownership, &wake);
            try wake.appendSlice(a, scheduled);
            if (ownership == .acquire) try ensureOwnershipCapacity(self, value.id);
            try self.runnable.ensureUnusedCapacity(self.allocator, wake.items.len);
            try store(self).putTask(successor, previous);
            try self.namespace.commit(transition);
            if (ownership == .acquire) claim(self, value.id);
            for (wake.items) |subject| subjectAddAssumeCapacity(self, subject);
        }
        pub fn snapshotRecord(
            self: *Self,
            comptime T: type,
            a: std.mem.Allocator,
            comptime kind: []const u8,
            id: state.Digest,
            task_id: state.TaskId,
        ) !state.Reference {
            if (T != storage.Record(kind)) @compileError("native record type/kind mismatch");
            const bytes = (try store(self).recordBytes(a, kind, id, task_id)) orelse
                return error.CorruptState;
            defer a.free(bytes);
            return store(self).putObject(bytes);
        }
    };
}
