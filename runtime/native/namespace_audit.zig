const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("state.zig");
const storage = @import("store.zig");
const registry = @import("registry.zig");
const retention = @import("retention.zig");

pub const Value = struct {
    task: state.TaskId,
    application_id: []const u8,
    schema_id: []const u8,
    kind: enum { input, output, failure },
    encoding: enum { contract, json },
    bytes: []const u8,
};

pub const Decoder = struct {
    context: ?*anyopaque = null,
    validate: *const fn (?*anyopaque, Value) anyerror!void,
};

pub const Report = struct {
    retention: retention.Statistics,
    application_readability: enum { not_assessed, verified },
    continuation_compatibility: enum { not_assessed } = .not_assessed,
    tasks: u64 = 0,
    nonterminal_tasks: u64 = 0,
};

pub fn verify(
    store: *storage.Store,
    handlers: registry.Registry,
    decoder: ?Decoder,
) !Report {
    var report: Report = .{
        .retention = try retention.verify(store, handlers),
        .application_readability = if (decoder != null) .verified else .not_assessed,
    };
    var rows = try store.database.prepare("SELECT body FROM tasks ORDER BY id", &.{});
    defer rows.deinit();
    while (try rows.step() == .row) {
        const digest = try rows.bytes(0);
        if (digest.len != 32) return error.CorruptState;
        const reference = try store.objectReference(digest[0..32].*, null);
        const bytes = try store.object(store.allocator, reference, null);
        defer store.allocator.free(bytes);
        var task = try contracts.decodeOwned(state.Task, store.allocator, bytes);
        defer task.deinit();
        report.tasks = try std.math.add(u64, report.tasks, 1);
        if (!task.value.terminal()) {
            report.nonterminal_tasks = try std.math.add(u64, report.nonterminal_tasks, 1);
        }
        if (decoder) |selected| try application(store, task.value, selected);
    }
    return report;
}

fn application(store: *storage.Store, task: state.Task, decoder: Decoder) !void {
    const input = try store.object(store.allocator, task.input, null);
    defer store.allocator.free(input);
    try decoder.validate(decoder.context, .{
        .task = task.id,
        .application_id = task.application_id.bytes,
        .schema_id = task.input_schema_id.bytes,
        .kind = .input,
        .encoding = .contract,
        .bytes = input,
    });
    const schema = switch (task.outcome_kind) {
        .completed => task.output_schema_id.bytes,
        .failed => task.failure_schema_id.bytes,
        else => return,
    };
    var value: Value = .{
        .task = task.id,
        .application_id = task.application_id.bytes,
        .schema_id = schema,
        .kind = if (task.outcome_kind == .completed) .output else .failure,
        .encoding = .contract,
        .bytes = undefined,
    };
    try contractResult(store, task, decoder, value);
    const json = try store.object(
        store.allocator,
        task.client_result orelse return error.CorruptState,
        null,
    );
    defer store.allocator.free(json);
    value.encoding = .json;
    value.bytes = json;
    try decoder.validate(decoder.context, value);
}

fn contractResult(
    store: *storage.Store,
    task: state.Task,
    decoder: Decoder,
    value: Value,
) !void {
    const bytes = try store.object(
        store.allocator,
        task.result orelse return error.CorruptState,
        null,
    );
    defer store.allocator.free(bytes);
    var result = value;
    if (task.outcome_kind == .completed) {
        result.bytes = bytes;
        return decoder.validate(decoder.context, result);
    }
    var outcome = try data.invocation.decode(data.invocation.Outcome, store.allocator, bytes);
    defer outcome.deinit();
    if (outcome.value != .failed) return error.CorruptState;
    result.bytes = outcome.value.failed.value;
    try decoder.validate(decoder.context, result);
}
