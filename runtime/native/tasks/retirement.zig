const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("../state.zig");
const storage = @import("../store.zig");
const archive = @import("../archive.zig");
const historical = @import("../historical_index.zig");
const task_types = @import("types.zig");
const json = @import("../json.zig");
const wc = contracts.workspace;

pub const Owner = struct {
    snapshot: contracts.Decoded(state.Archive),
    task: contracts.Decoded(state.Task),

    pub fn deinit(self: *Owner) void {
        self.task.deinit();
        self.snapshot.deinit();
    }
};

pub const Read = struct {
    view: historical.HistoricalIndex,

    pub fn open(store: *storage.Store, owner: Owner) !Read {
        if (store.projecting or store.transaction) return error.Busy;
        const view = try historical.HistoricalIndex.open(
            store,
            owner.snapshot.value,
            owner.task.value,
        );
        store.projecting = true;
        return .{ .view = view };
    }

    pub fn close(self: *Read) !void {
        self.view.store.projecting = false;
        try self.view.close();
    }
};

pub const Answer = struct {
    operation_id: []const u8,
    task: state.TaskId,
    question: state.Digest,
    revision: u64,
    request: state.Digest,
    schema: []const u8,
    json: json.Value,
};

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Messages = @import("messages.zig").Operations(Types, Self);
        const Transport = @import("placement_transport.zig").Operations(Types, Self);

        pub fn owner(self: *Self, a: std.mem.Allocator, task: state.TaskId) !?Owner {
            try Lifecycle.allowed(self);
            const store = Lifecycle.store(self);
            var snapshot = (try store.retirement(a, task)) orelse return null;
            errdefer snapshot.deinit();
            const bytes = try store.object(a, snapshot.value.task, null);
            defer a.free(bytes);
            var saved = try contracts.decodeOwned(state.Task, a, bytes);
            errdefer saved.deinit();
            if (!std.meta.eql(saved.value.id, task) or !saved.value.terminal())
                return error.CorruptState;
            if (!std.mem.eql(u8, saved.value.principal.bytes, self.profile.authority.principal) or
                !std.mem.eql(u8, saved.value.tenant.bytes, self.profile.authority.tenant))
                return error.Denied;
            return .{ .snapshot = snapshot, .task = saved };
        }

        pub fn receipt(
            self: *Self,
            a: std.mem.Allocator,
            id: []const u8,
            task: state.TaskId,
        ) !contracts.Decoded(state.Receipt) {
            const key = try Records.operationKey(self, a, id);
            const bytes = (try Lifecycle.store(self).savedReceipt(a, &key)) orelse
                return error.UnknownTask;
            defer a.free(bytes);
            var saved = try contracts.decodeOwned(state.Receipt, a, bytes);
            errdefer saved.deinit();
            if (!std.meta.eql(saved.value.task, task)) return error.OperationConflict;
            return saved;
        }

        pub fn placement(
            self: *Self,
            a: std.mem.Allocator,
            retired: Owner,
            operation_id: []const u8,
            request: wc.Placement,
        ) !wc.Reply {
            const p = @import("../placement.zig");
            const site = try Lifecycle.placementSite(self);
            const task = retired.task.value.id;
            const id = p.operationId(site, task, operation_id, .action);
            const ref = archive.record(retired.snapshot.value, .placement_action, id) orelse
                return error.UnknownTask;
            const bytes = try Lifecycle.store(self).object(a, ref, null);
            defer a.free(bytes);
            var prior = try contracts.decodeOwned(p.ActionRecord, a, bytes);
            defer prior.deinit();
            if (!std.meta.eql(prior.value.task, task) or !std.meta.eql(prior.value.id, id))
                return error.CorruptState;
            try p.verify(p.Action, a, prior.value.action, site);
            const wanted = try contracts.encodeOwned(wc.Placement, a, request);
            defer a.free(wanted);
            const actual = try contracts.encodeOwned(
                wc.Placement,
                a,
                prior.value.action.value.request,
            );
            defer a.free(actual);
            if (!std.mem.eql(u8, wanted, actual)) return error.OperationConflict;
            return Transport.placementReplyCopy(a, prior.value.action.value.reply);
        }

        pub fn respond(
            self: *Self,
            a: std.mem.Allocator,
            input: Answer,
        ) !?task_types.Admission {
            var retired = (try owner(self, a, input.task)) orelse return null;
            defer retired.deinit();
            var saved = try receipt(self, a, input.operation_id, input.task);
            defer saved.deinit();
            if (saved.value.method != .respond) return error.OperationConflict;
            const reference = archive.record(
                retired.snapshot.value,
                .question,
                input.question,
            ) orelse return error.StaleInteraction;
            const bytes = try Lifecycle.store(self).object(a, reference, null);
            defer a.free(bytes);
            var question = try contracts.decodeOwned(state.Question, a, bytes);
            defer question.deinit();
            if (question.value.revision != input.revision or
                !std.meta.eql(question.value.request_digest, input.request) or
                !std.mem.eql(u8, question.value.answer_schema_id.bytes, input.schema))
                return error.StaleInteraction;
            const answer = try Messages.encodeAnswer(
                self,
                a,
                input.schema,
                question.value,
                input.json,
            );
            defer a.free(answer);
            const request = try task_types.answerDigest(
                a,
                input.task,
                input.question,
                input.revision,
                input.request,
                input.schema,
                answer,
            );
            return (try Records.replay(self, a, input.operation_id, request)) orelse
                error.CorruptState;
        }
    };
}
