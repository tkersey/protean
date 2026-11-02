const std = @import("std");
const state = @import("../state.zig");

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Queries = @import("task_queries.zig").Operations(Types, Self);
        const Scheduling = @import("scheduling.zig").Operations(Types, Self);

        pub fn discardTask(self: *Self, a: std.mem.Allocator, task_id: state.TaskId) !void {
            try Lifecycle.allowed(self);
            if (self.work != null or self.placement_job != null or
                self.placement_pending.items.len != 0) return error.Busy;
            try Lifecycle.requireCustody(self, a, task_id, null);
            var parent = try self.task(a, task_id);
            defer parent.deinit();
            if (!try Queries.taskCleanupComplete(self, a, parent.value)) return error.InvalidState;
            if (self.active) |active| {
                if (std.meta.eql(active.task, task_id)) try Lifecycle.retire(self, a);
            }
            const store = Lifecycle.store(self);
            try store.begin();
            defer store.rollback();
            try Lifecycle.allowed(self);
            try Lifecycle.requireCustody(self, a, task_id, null);
            try store.eraseTask(task_id, parent.value.revision);
            store.invalidateIntegrity();
            try self.namespace.commit("task.discard");
            var index: usize = 0;
            while (index < self.runnable.items.len) {
                const subject = self.runnable.items[index];
                if (std.meta.eql(subject.task, task_id)) {
                    Scheduling.subjectRemove(self, subject);
                } else index += 1;
            }
            Scheduling.unclaim(self, task_id);
        }
    };
}
