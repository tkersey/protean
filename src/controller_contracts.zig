const c = @import("contracts.zig");

pub const identity = "protean-controller/1";
pub const import_prefix = "controller/1/";
pub const effect_prefix = "protean.controller/1/";
pub const boot_identity = effect_prefix ++ "boot_ready";
pub const offer_identity = effect_prefix ++ "offer";
pub const handoff_identity = effect_prefix ++ "handoff";
pub const TaskAnchor = struct { task: [16]u8 };
pub const Import = enum {
    task_view,
    deliberate,
    workspace,
    question,
    inbox,
    snapshot,
    inspect,
    context,
};
pub const Diagnostic = struct {
    operation: [32]u8,
    code: c.Utf8,
    observation: c.Utf8,
};
pub const Reference = struct { digest: [32]u8, bytes: u64 };
pub const WorkFact = struct {
    work: c.workspace.Ref,
    execution_revision: u64,
    control_revision: u64,
    event_watermark: u64,
    observation: c.Utf8,
};
pub const OwnerView = struct {
    task: [16]u8,
    event_cut: u64,
    next_message: u64,
    policy: [32]u8,
    input_schema: c.Bytes(null),
    input: c.Bytes(null),
    messages: c.Vector(c.Bytes(null), null),
    works: c.Vector(WorkFact, null),
};
pub fn Reply(comptime Result: type) type {
    return struct { response: Result, diagnostic: ?Diagnostic = null };
}

pub const Signature = struct {
    import: Import,
    payload: c.Bytes(null),
    result: c.Bytes(null),
    native_result: ?c.Bytes(null) = null,
};

pub const Contract = struct {
    result: c.Bytes(null),
    failure: c.Bytes(null),
    imports: c.Vector(Signature, null),
};

pub const Binding = struct {
    import: Import,
    identity: c.Utf8,
    payload: c.Bytes(null),
    result: c.Bytes(null),
    public_result: ?c.Bytes(null) = null,
};

pub const Descriptor = struct {
    contract: c.Utf8,
    private_input: c.Bytes(null),
    carry: c.Bytes(null),
    handoff_payload: c.Bytes(null),
    imports: c.Vector(Binding, null),
};
