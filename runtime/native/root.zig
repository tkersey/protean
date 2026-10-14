//! Compiled native environment. Deliberately separate from Protean authoring.
pub const json = @import("json.zig");
pub const values = @import("values.zig");
pub const protocol = @import("protocol.zig");
pub const registry = @import("registry.zig");
pub const Context = registry.Context;
pub const leaf = registry.leaf;
pub const question = registry.question;
pub const Declaration = registry.Declaration;
pub const Registry = registry.Registry;
pub const run = @import("host.zig").run;
pub const reportFailure = @import("host.zig").reportFailure;
pub const discovery = @import("discovery.zig");
pub const inbox = @import("inbox.zig");
pub const https = @import("https.zig");
pub const responses = @import("responses.zig");
pub const adaptive_responses = @import("adaptive_responses.zig");
pub const repository = @import("repository.zig");
pub const tool_construction = @import("tool_construction.zig");
pub const configuration = @import("configuration.zig");
pub const tasks = @import("tasks.zig");
pub const client = @import("client.zig");
pub const Namespace = @import("namespace.zig").Namespace;

test {
    _ = json;
    _ = values;
    _ = protocol;
    _ = https;
    _ = repository;
    _ = registry;
    _ = client;
    _ = discovery;
    _ = @import("occurrence.zig");
    _ = @import("store.zig");
    _ = @import("namespace.zig");
    _ = @import("transport.zig");
    _ = @import("host.zig");
    _ = @import("driver.zig");
}

// Private history internals are exposed only to the repository's test graph.
pub const testing = if (@import("builtin").is_test) struct {
    pub const adaptive_history = @import("adaptive_history.zig");
    pub const state = @import("state.zig");
    pub const occurrence = @import("occurrence.zig");
    pub const Worker = @import("worker.zig").Worker;
} else struct {};
