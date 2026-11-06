const std = @import("std");
const contracts = @import("protean_contracts");
const json = @import("json.zig");
const values = @import("values.zig");

pub const Contract = contracts.ResponsesContract;
pub const Route = contracts.ResponsesRoute;
pub const endpoint = "https://api.openai.com/v1/responses";

pub fn read(a: std.mem.Allocator, profile: []const u8) !Contract {
    var parsed = try json.parse(a, profile, .{
        .bytes = profile.len,
        .tokens = profile.len,
        .members = profile.len,
    });
    defer parsed.deinit();
    const value = json.get(parsed.value, "responses") orelse return .{};
    const contract = try values.fromJson(Contract, a, value);
    try validate(contract);
    return contract;
}

pub fn validate(contract: Contract) !void {
    if (contract.version != 1 or
        (contract.route == .chatgpt_plan_sse) != (contract.binding != null))
        return error.IncompatibleResponsesContract;
}

pub fn format(route: Route) contracts.ResponseFormat {
    return if (route == .chatgpt_plan_sse) .sse else .json;
}

pub fn admitProfile(route: Route, profile: anytype) !void {
    if (route == .api_key_json) return;
    if (profile.max_output_tokens != null or profile.reasoning_mode != .standard or
        profile.reasoning_context != .auto or profile.explicit_cache or
        profile.cache_diagnostics or profile.effort_update or !profile.additional_tools)
        return error.UnsupportedChatGPTCapability;
}

pub const Envelope = struct {
    route: Route,
    model: []const u8,
    effort: []const u8,
    reasoning_mode: []const u8,
    reasoning_context: []const u8,
    max_output_tokens: ?u32,
    input: json.Value,
    tools: json.Value,
};

pub fn envelope(a: std.mem.Allocator, spec: Envelope) !json.Value {
    if (spec.input != .array or spec.tools != .array) return error.InvalidPreparedRequest;
    const plan = spec.route == .chatgpt_plan_sse;
    if (plan and (spec.max_output_tokens != null or
        !std.mem.eql(u8, spec.reasoning_mode, "standard") or
        !std.mem.eql(u8, spec.reasoning_context, "auto")))
        return error.UnsupportedChatGPTCapability;
    var body = json.object();
    try json.put(a, &body, "model", json.string(spec.model));
    try json.put(a, &body, "input", if (plan)
        try withCoreTools(a, spec.input, spec.tools)
    else
        spec.input);
    if (!plan) try json.put(a, &body, "tools", spec.tools);
    var reasoning = json.object();
    try json.put(a, &reasoning, "effort", json.string(spec.effort));
    if (!plan) {
        try json.put(a, &reasoning, "mode", json.string(spec.reasoning_mode));
        try json.put(a, &reasoning, "context", json.string(spec.reasoning_context));
        if (spec.max_output_tokens) |maximum|
            try json.put(a, &body, "max_output_tokens", try json.number(a, maximum));
        try json.put(a, &body, "background", .{ .bool = false });
        try json.put(a, &body, "truncation", json.string("disabled"));
    }
    try json.put(a, &body, "reasoning", reasoning);
    try json.put(a, &body, "parallel_tool_calls", .{ .bool = false });
    try json.put(a, &body, "store", .{ .bool = false });
    try json.put(a, &body, "stream", .{ .bool = plan });
    return body;
}

fn withCoreTools(a: std.mem.Allocator, input: json.Value, tools: json.Value) !json.Value {
    var result: json.Value = .{ .array = .init(a) };
    var prefix = json.object();
    try json.put(a, &prefix, "type", json.string("additional_tools"));
    try json.put(a, &prefix, "role", json.string("developer"));
    try json.put(a, &prefix, "tools", tools);
    try result.array.append(prefix);
    for (input.array.items) |item| {
        if (json.get(item, "role")) |role| if (role == .string and
            std.mem.eql(u8, role.string, "system")) return error.UnsupportedChatGPTCapability;
        try result.array.append(item);
    }
    return result;
}
