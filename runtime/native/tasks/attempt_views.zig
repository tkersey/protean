const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const types = @import("types.zig");

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const Queries = @import("task_queries.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);

        pub fn attemptPage(
            self: *Self,
            a: std.mem.Allocator,
            id: state.TaskId,
            expected_revision: u64,
            after: ?state.Digest,
            limit: u32,
        ) !types.AttemptPage {
            var owner = try checkedTask(self, a, id, expected_revision);
            defer owner.deinit();
            if (limit == 0) return error.InvalidParams;
            var arena = std.heap.ArenaAllocator.init(a);
            errdefer arena.deinit();
            const scratch = arena.allocator();
            const cursor = after orelse @as(state.Digest, @splat(0));
            var rows = if (after != null) try Lifecycle.store(self).database.prepare(
                "SELECT id FROM records WHERE task=? AND kind='attempt' " ++
                    "AND id>? ORDER BY id LIMIT ?",
                &.{ .{ .blob = &id }, .{ .blob = &cursor }, .{ .integer = limit } },
            ) else try Lifecycle.store(self).database.prepare(
                "SELECT id FROM records WHERE task=? AND kind='attempt' ORDER BY id LIMIT ?",
                &.{ .{ .blob = &id }, .{ .integer = limit } },
            );
            defer rows.deinit();
            var entries: std.ArrayList(types.AttemptView) = .empty;
            while (try rows.step() == .row) {
                const bytes = try rows.bytes(0);
                if (bytes.len != 32) return error.CorruptState;
                const value = try readAttempt(self, scratch, owner.value, bytes[0..32].*);
                try entries.append(scratch, value);
            }
            const next = if (entries.items.len == limit) entries.items[limit - 1].id else null;
            const attempts = try entries.toOwnedSlice(scratch);
            return .{
                .arena = arena,
                .task = id,
                .revision = expected_revision,
                .attempts = attempts,
                .next = next,
            };
        }

        pub fn attemptValue(
            self: *Self,
            a: std.mem.Allocator,
            id: state.TaskId,
            expected_revision: u64,
            attempt_id: state.Digest,
            part: types.AttemptValuePart,
        ) !?types.AttemptValue {
            var owner = try checkedTask(self, a, id, expected_revision);
            defer owner.deinit();
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const attempt = try readAttempt(self, arena.allocator(), owner.value, attempt_id);
            const capture = attempt.capture orelse return null;
            const reference = (switch (part) {
                .response => capture.response,
                .reply => capture.reply,
            }) orelse return null;
            return .{
                .allocator = a,
                .task = id,
                .revision = expected_revision,
                .attempt = attempt_id,
                .part = part,
                .reference = reference,
                .bytes = try Lifecycle.store(self).object(a, reference, null),
            };
        }

        fn checkedTask(
            self: *Self,
            a: std.mem.Allocator,
            id: state.TaskId,
            expected_revision: u64,
        ) !contracts.Decoded(state.Task) {
            var owner = try Queries.task(self, a, id);
            errdefer owner.deinit();
            if (owner.value.revision != expected_revision) return error.StaleRevision;
            return owner;
        }

        fn readAttempt(
            self: *Self,
            a: std.mem.Allocator,
            owner: state.Task,
            id: state.Digest,
        ) !types.AttemptView {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const scratch = arena.allocator();
            var saved = try Records.record(self, state.Attempt, scratch, "attempt", id, owner.id);
            defer saved.deinit();
            const attempt = saved.value;
            var pending = try Records.record(
                self,
                occurrence.Occurrence,
                scratch,
                "occurrence",
                attempt.occurrence,
                owner.id,
            );
            defer pending.deinit();
            if (!std.meta.eql(attempt.task, owner.id) or !std.meta.eql(attempt.id, id) or
                !std.meta.eql(attempt.profile, owner.profile) or
                !std.meta.eql(pending.value.task, owner.id) or
                !std.meta.eql(pending.value.id, attempt.occurrence) or
                !std.meta.eql(pending.value.request_object, attempt.request))
                return error.CorruptState;
            var request = try data.invocation.decode(
                data.invocation.Request,
                scratch,
                try Lifecycle.store(self).object(scratch, attempt.request, null),
            );
            defer request.deinit();
            if (!std.meta.eql(request.value.request_identity, pending.value.request))
                return error.CorruptState;
            if (attempt.prepared) |reference| try requireReference(self, reference);
            return .{
                .id = id,
                .occurrence = attempt.occurrence,
                .capability = try a.dupe(u8, attempt.capability.bytes),
                .inference = attempt.inference,
                .request = attempt.request,
                .prepared = attempt.prepared,
                .capture = try readCapture(self, scratch, attempt, pending.value),
            };
        }

        fn requireReference(self: *Self, reference: state.Reference) !void {
            const retained = try Lifecycle.store(self).objectReference(reference.digest, null);
            if (!std.meta.eql(retained, reference)) return error.CorruptState;
        }

        fn readCapture(
            self: *Self,
            a: std.mem.Allocator,
            attempt: state.Attempt,
            pending: occurrence.Occurrence,
        ) !@FieldType(types.AttemptView, "capture") {
            const bytes = (try Lifecycle.store(self).recordBytes(
                a,
                "capture",
                attempt.id,
                attempt.task,
            )) orelse return null;
            var decoded = try contracts.decodeOwned(state.Capture, a, bytes);
            defer decoded.deinit();
            const capture = decoded.value;
            if (!std.meta.eql(capture.task, attempt.task) or
                !std.meta.eql(capture.attempt, attempt.id) or
                !std.meta.eql(capture.occurrence, attempt.occurrence) or
                attempt.prepared == null or
                !std.meta.eql(capture.request, attempt.prepared.?) or
                (capture.disposition == .complete) != (capture.response != null))
                return error.CorruptState;
            try validateCaptureState(capture, pending);
            if (capture.response) |reference| try requireReference(self, reference);
            if (capture.projection) |projection| {
                var reply = try data.invocation.decode(
                    data.invocation.Result,
                    a,
                    try Lifecycle.store(self).object(a, projection.reply, null),
                );
                defer reply.deinit();
                if (!std.meta.eql(reply.value.request_identity, pending.request))
                    return error.CorruptState;
            }
            return .{
                .disposition = capture.disposition,
                .response = capture.response,
                .reply = if (capture.projection) |projection| projection.reply else null,
                .output_tokens = if (capture.projection) |projection|
                    projection.output_tokens
                else
                    null,
            };
        }

        fn validateCaptureState(capture: state.Capture, pending: occurrence.Occurrence) !void {
            if (capture.disposition == .definitely_not_sent) {
                if (capture.projection != null or capture.reconciliation != null or
                    !occurrence.nonTransmissionConsistent(pending.state, capture.attempt))
                    return error.CorruptState;
                return;
            }
            if (capture.projection != null and capture.disposition != .complete)
                return error.CorruptState;
        }
    };
}
