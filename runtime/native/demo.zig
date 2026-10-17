//! Deterministic client scenario through the same durable owner as stdio. The
//! authored application, not this scenario, chooses effects and control flow.
const std = @import("std");
const Worker = @import("worker.zig").Worker;
const c = @import("native_c");
const tasks = @import("tasks.zig");
const client_api = @import("client.zig");
const json = @import("json.zig");
const values = @import("values.zig");

pub fn run(comptime Types: type, comptime Environment: type, a: std.mem.Allocator, service: *tasks.Service(Types), client: *client_api.Client(Types), operation_id: []const u8) !json.Value {
    const slot = try Worker.init(a, service.io);
    defer slot.deinit(a) catch unreachable;
    const accepted = try service.submit(a, operation_id, Environment.demo_input);
    var effects: u32 = 0;
    var yields: u32 = 0;
    // A scheduler turn may now be only an outer evaluator slice. It is not a
    // guest transition or an effect, so it cannot impose a task lifetime quota.
    while (true) {
        // Requests and projections are already durably owned by the service.
        // Keep only this iteration's decoded values; a long adaptive demo must
        // not retain every historical decoding in the caller's report arena.
        var iteration = std.heap.ArenaAllocator.init(a);
        defer iteration.deinit();
        const frame = iteration.allocator();
        const step = try service.pump(frame);
        switch (step) {
            .work => |work| {
                slot.start(work, service.profile.authority, service.profile.environment) catch |err| {
                    try service.notSent(frame, work);
                    return err;
                };
                // Offline demo has no interactive input loop. Use the same
                // acquisition path as CLI/stdio, including raw captures and
                // definitely-not-sent versus unknown delivery classification.
                while (!slot.finished()) _ = c.poll(null, 0, 1);
                try slot.join();
                defer slot.release() catch unreachable;
                const result = slot.result orelse .not_sent;
                try service.completeWork(frame, work, result);
                if (result == .unknown or result == .not_sent) return slot.failure orelse error.DemoDidNotComplete;
                effects += 1;
            },
            .waiting => {
                var question = (try service.pendingQuestion(frame, accepted.receipt.task)) orelse return error.DemoDidNotComplete;
                defer question.deinit();
                const id = try std.fmt.allocPrint(frame, "demo-answer-{s}", .{std.fmt.bytesToHex(question.value.id, .lower)});
                _ = try service.respond(frame, id, accepted.receipt.task, question.value.id, question.value.revision, question.value.request_digest, question.value.answer_schema_id.bytes, try values.toJson(Types.Answer, frame, Environment.demo_answer));
                effects += 1;
            },
            .progressed, .idle => {},
        }
        var current = try service.task(frame, accepted.receipt.task);
        defer current.deinit();
        if (current.value.outcome_kind == .yielded) yields += 1;
        if (!current.value.terminal()) continue;
        if (current.value.outcome_kind != .completed) return error.DemoDidNotComplete;
        var params = json.object();
        try json.put(a, &params, "task_id", json.string(try a.dupe(u8, &std.fmt.bytesToHex(accepted.receipt.task, .lower))));
        const result = try client.call(a, .@"task.result", params);
        var report = json.object();
        try json.put(a, &report, "mode", json.string("offline-demo"));
        try json.put(a, &report, "persistence", json.string("durable"));
        try json.put(a, &report, "effects", try json.number(a, effects));
        try json.put(a, &report, "yields", try json.number(a, yields));
        try json.put(a, &report, "task_id", params.object.get("task_id").?);
        try json.put(a, &report, "output", result.object.get("outcome").?.object.get("value") orelse return error.DemoCapacity);
        return report;
    }
}
