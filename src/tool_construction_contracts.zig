//! Ordinary variable-length values shared by tool authoring and native execution.
const contracts = @import("contracts.zig");

pub const Name = contracts.Utf8;
pub const Component = struct { id: Name, object: contracts.Bytes(null) };
pub const Catalog = contracts.Vector(Component, null);
pub const Endpoint = struct { instance: Name, symbol: Name };
pub const Recipe = struct {
    instances: contracts.Vector(struct { key: Name, component_id: Name }, null),
    bindings: contracts.Vector(struct { required: Endpoint, supplied: Endpoint }, null),
    entry: Endpoint,
};
pub const Interface = struct {
    input: contracts.Bytes(null),
    output: contracts.Bytes(null),
    failure: contracts.Bytes(null),
};
pub const Built = struct { image: contracts.Bytes(null), interface: Interface };

/// A derived product remains bound to its creating task and frozen policy.
/// The ordinary object store supplies the reference to these canonical bytes.
pub const Program = struct {
    version: u8 = 2,
    task: [16]u8,
    policy: [32]u8,
    catalog: [32]u8,
    recipe: contracts.Utf8,
    built: Built,
};
pub const Input = struct { schema: contracts.Bytes(null), value: contracts.Bytes(null) };
