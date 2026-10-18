//! Bilateral execution custody. Signatures identify conforming native owners;
//! they do not prove peer honesty or grant environmental adapter authority.
//! No deadline or transport failure releases a frozen source.
const std = @import("std");
const contracts = @import("protean_contracts");
const state = @import("state.zig");
const Ed25519 = std.crypto.sign.Ed25519;
pub const Digest = state.Digest;
pub const Site = struct { key: [32]u8, namespace: Digest };
pub const Subject = struct { task: state.TaskId, work: ?Digest = null };
pub const Configuration = struct {
    /// Launch-owned secret; it is never part of a persisted protocol record.
    signing_key: Ed25519.KeyPair,
    peers: []const Peer,
    /// Operator-owned private directory outside the execution namespace.
    transport_directory: ?[]const u8 = null,
};
pub const Channel = struct { argv: []const []const u8, remote_name: []const u8, timeout_ms: u32 = 30000 };
pub const Peer = struct {
    name: []const u8,
    site: Site,
    native_build: Digest,
    compatibility: Compatibility,
    resource_binding: Digest,
    disclosure_policy: Digest,
    archive_limit: ?u64 = null,
    channel: ?Channel = null,
    context: *anyopaque,
    /// Called over the exact authenticated transport closure. The operator
    /// owns classification and policy; generated values cannot supply this
    /// function or bypass it with claimed labels.
    disclose: *const fn (*anyopaque, Subject, []const state.Reference) anyerror!void,
};
pub const Compatibility = struct {
    base: Digest,
    admission: Digest,
    bridge: Digest,
    semantics: Digest,
    private_state: Digest,
};
/// A signed observation may name an object that exists only at another site.
/// Its identity is not a local retention edge or authority to import that object.
pub const ObjectIdentity = struct {
    digest: Digest,
    bytes: u64,

    pub fn from(value: state.Reference) ObjectIdentity {
        return .{ .digest = value.digest, .bytes = value.bytes };
    }
    pub fn optional(value: ?state.Reference) ?ObjectIdentity {
        return if (value) |reference| from(reference) else null;
    }
};
pub const Cut = struct {
    execution: u64,
    control: u64,
    realization: u64,
    checkpoint: ObjectIdentity,
    outer: ?ObjectIdentity = null,
    runtime: ?ObjectIdentity = null,
};
/// The full closure is admitted for disclosure, including literals, private
/// reconstruction state and traces. This digest names that exact decision.
pub const Intent = struct {
    transfer: Digest,
    subject: Subject,
    source: Site,
    destination: Site,
    source_native: Digest,
    destination_native: Digest,
    epoch: u64,
    cut: Cut,
    compatibility: Compatibility,
    resources: Digest,
    disclosure: Digest,
};
pub const Offer = struct {
    intent: Intent,
    // Archive files are transport objects, not nominal Store references.
    archive_digest: Digest,
    archive_bytes: u64,
};
pub const Refusal = enum { incompatible, disclosure, resources, capacity, withdrawn };
pub const Decision = struct {
    transfer: Digest,
    offer_digest: Digest,
    source: Site,
    destination: Site,
    epoch: u64,
    verdict: union(enum) { accepted: void, refused: Refusal },
};
pub const Control = struct {
    subject: Subject,
    controller: Site,
    controller_epoch: u64,
    executor: Site,
    custody_epoch: u64,
    operation: state.Name,
    command: contracts.workspace.Work,
    expansion: ?struct { reference: contracts.workspace.Ref, page: contracts.workspace.Page } = null,
    /// The controller's durable cancellation event revision. It orders repeated
    /// cleanup requests without comparing clocks across namespaces.
    cleanup_request: ?u64 = null,
};
/// Signed lifecycle facts from the current executor. These are observations;
/// they carry no local continuation, value reference, or environmental grant.
pub const WorkState = struct {
    observed_at: u64,
    execution_revision: u64,
    control_revision: u64,
    outcome: state.Outcome,
    cleanup_complete: bool,
    cancellation: ?state.Reason,
    explicitly_parked: bool = false,
    park_complete: bool = false,

    pub fn parkSettled(self: WorkState) bool {
        return self.cancellation == null and self.explicitly_parked and self.park_complete;
    }
};
pub const Report = struct {
    control: Digest,
    executor: Site,
    custody_epoch: u64,
    reply: contracts.workspace.Reply,
    work_state: ?WorkState = null,
};
pub const ControlRecord = struct {
    id: Digest,
    task: state.TaskId,
    control: Signed(Control),
    route: contracts.Vector(Succession, null) = .{ .items = &.{} },
    report: ?Signed(Report) = null,
    last_error: ?state.Name = null,
};
pub const Hello = struct { site: Site, native_build: Digest, challenge: Digest };
pub const Action = struct {
    id: Digest,
    task: state.TaskId,
    owner: Site,
    operation: state.Name,
    request: contracts.workspace.Placement,
    reply: contracts.workspace.Reply,
};
pub const ActionRecord = struct { id: Digest, task: state.TaskId, action: Signed(Action) };
pub const Succession = struct { id: Digest, task: state.TaskId, offer: Signed(Offer), decision: Signed(Decision) };
pub const Executor = struct { site: Site, epoch: u64 };
pub const ControlResolution = union(enum) { report: Signed(Report), next: Succession };

/// A route extends the original signed command without changing its identity.
/// Every edge is an accepted bilateral transfer of that exact work subject.
pub fn routeNext(a: std.mem.Allocator, subject: Subject, current: Executor, next: Succession) !Executor {
    const intent = next.offer.value.intent;
    try verify(Offer, a, next.offer, current.site);
    try matchDecision(a, next.offer.value, next.decision);
    if (!std.meta.eql(subject, intent.subject) or subject.work == null or
        !std.meta.eql(next.task, subject.task) or !std.meta.eql(next.id, intent.transfer) or
        intent.epoch != current.epoch or next.decision.value.verdict != .accepted) return error.InvalidRemoteCommand;
    return .{ .site = next.decision.value.destination, .epoch = next.decision.value.epoch };
}
pub fn routeHead(a: std.mem.Allocator, control: Control, route: []const Succession) !Executor {
    var current: Executor = .{ .site = control.executor, .epoch = control.custody_epoch };
    for (route) |next| current = try routeNext(a, control.subject, current, next);
    return current;
}
pub fn matchReport(a: std.mem.Allocator, control: Control, route: []const Succession, report: Signed(Report)) !void {
    var current: Executor = .{ .site = control.executor, .epoch = control.custody_epoch };
    var matches = std.meta.eql(current.site, report.value.executor) and current.epoch == report.value.custody_epoch;
    for (route) |next| {
        current = try routeNext(a, control.subject, current, next);
        matches = matches or (std.meta.eql(current.site, report.value.executor) and current.epoch == report.value.custody_epoch);
    }
    if (!matches or !std.meta.eql(report.value.control, try digest(Control, a, control))) return error.InvalidRemoteCommand;
    try verify(Report, a, report, report.value.executor);
}
/// Source-local retained export. It is never part of another transfer's
/// archive: copied custody cannot acquire the source's publication obligation.
pub const Snapshot = struct {
    id: Digest,
    task: state.TaskId,
    work: ?Digest,
    frozen: ?struct { intent: Intent, manifest: state.Archive },
};

pub const Move = struct {
    id: Digest,
    task: state.TaskId,
    owner: Site,
    action: state.Reference,
    request: @FieldType(contracts.workspace.Placement, "move"),
    subject: Subject,
    expected: ?Cut,
    decision: ?Signed(Decision) = null,
    withdraw_requested: bool = false,
    cancelled: bool = false,
    last_error: ?state.Name = null,
};
/// Native stdio requests. Paths and signed peer messages never enter the
/// authored guest or the model's placement action schema.
pub const Request = union(enum) {
    identify: struct {},
    challenge: Digest,
    status: Subject,
    cut: Subject,
    compatibility: Subject,
    freeze: struct { subject: Subject, peer: state.Name, expected: Cut, transfer: Digest },
    move: struct { subject: Subject, peer: state.Name, expected: Cut, transfer: Digest },
    offer: struct { subject: Subject, peer: state.Name, path: contracts.Utf8 },
    accept: struct { operation: state.Name, peer: state.Name, offer: Signed(Offer), path: contracts.Utf8 },
    stage: struct { peer: state.Name, offer: Signed(Offer), offset: u64, bytes: contracts.Bytes(32768) },
    accept_staged: struct { operation: state.Name, peer: state.Name, offer: Signed(Offer) },
    refuse: struct { peer: state.Name, offer: Signed(Offer), reason: Refusal },
    decision: struct { subject: Subject, decision: Signed(Decision) },
    abort_unsent: struct { subject: Subject, transfer: Digest },
    withdraw: struct { task: state.TaskId, transfer: Digest },
    control: struct { operation: state.Name, task: state.TaskId, command: contracts.workspace.Work },
    execute_control: struct { peer: state.Name, control: Signed(Control) },
    resolve_control: struct { peer: state.Name, control: Signed(Control), route: contracts.Vector(Succession, null) },
    report: struct { task: state.TaskId, control: Digest, report: Signed(Report) },
    follow_controller: struct { source: state.Name, destination: state.Name, offer: Signed(Offer), decision: Signed(Decision) },
    follow_controller_proof: struct { offer: Signed(Offer), decision: Signed(Decision) },
};
pub fn Signed(comptime T: type) type {
    return struct { value: T, signature: [64]u8 };
}
fn domain(comptime T: type) []const u8 {
    return if (T == Offer) "protean-placement/1/offer\x00" else if (T == Decision) "protean-placement/1/decision\x00" else if (T == Control) "protean-placement/1/control\x00" else if (T == Report) "protean-placement/1/report\x00" else if (T == Hello) "protean-placement/1/hello\x00" else if (T == Action) "protean-placement/1/action\x00" else @compileError("not a signed placement message");
}
fn signerOf(comptime T: type, value: T) Site {
    return if (T == Offer) value.intent.source else if (T == Decision) value.destination else if (T == Control) value.controller else if (T == Hello) value.site else if (T == Action) value.owner else value.executor;
}
pub fn operationId(site: Site, task: state.TaskId, operation_name: []const u8, kind: enum { action, move }) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("protean-placement/1/operation\x00");
    hash.update(@tagName(kind));
    hash.update(&site.key);
    hash.update(&site.namespace);
    hash.update(&task);
    hash.update(operation_name);
    return hash.finalResult();
}
pub fn digest(comptime T: type, a: std.mem.Allocator, value: T) !Digest {
    const bytes = try contracts.encodeOwned(T, a, value);
    defer a.free(bytes);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain(T));
    hash.update(bytes);
    return hash.finalResult();
}
pub fn sign(comptime T: type, a: std.mem.Allocator, key: Ed25519.KeyPair, value: T) !Signed(T) {
    const signer = signerOf(T, value);
    if (!std.meta.eql(signer.key, key.public_key.toBytes())) return error.KeyOwnerMismatch;
    return .{ .value = value, .signature = (try key.sign(&try digest(T, a, value), null)).toBytes() };
}
pub fn verify(comptime T: type, a: std.mem.Allocator, signed: Signed(T), expected: Site) !void {
    const signer = signerOf(T, signed.value);
    if (!std.meta.eql(signer, expected)) return error.KeyOwnerMismatch;
    const public = try Ed25519.PublicKey.fromBytes(expected.key);
    try Ed25519.Signature.fromBytes(signed.signature).verifyStrict(&try digest(T, a, signed.value), public);
}
pub fn subjectId(subject: Subject) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("protean-placement/1/subject\x00");
    hash.update(&subject.task);
    hash.update(&.{@intFromBool(subject.work != null)});
    if (subject.work) |work| hash.update(&work);
    return hash.finalResult();
}
pub fn controlId(control: Control) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("protean-placement/1/controller-operation\x00");
    hash.update(&control.subject.task);
    hash.update(&control.controller.key);
    hash.update(&control.controller.namespace);
    var epoch: [8]u8 = undefined;
    std.mem.writeInt(u64, &epoch, control.controller_epoch, .little);
    hash.update(&epoch);
    hash.update(control.operation.bytes);
    return hash.finalResult();
}
pub fn commandWork(command: contracts.workspace.Work) !contracts.workspace.Ref {
    return switch (command) {
        .inspect => |value| value.work,
        .advance, .park => |value| value.work,
        inline .pump, .delegate, .interact, .cancel, .realize, .request_cut => |value| value.expected.work,
        .start, .wait, .collect => error.InvalidRemoteCommand,
    };
}
pub const Custody = struct {
    id: Digest,
    task: state.TaskId,
    work: ?Digest,
    owner: Site,
    epoch: u64 = 0,
    phase: enum { local, frozen, away },
    intent: ?Intent = null,
    offer: ?Signed(Offer) = null,
    decision: ?Signed(Decision) = null,

    pub fn initial(subject: Subject, site: Site) Custody {
        return .{ .id = subjectId(subject), .task = subject.task, .work = subject.work, .owner = site, .phase = .local };
    }
    pub fn requireLocal(self: Custody, site: Site) !void {
        if (self.phase != .local or !std.meta.eql(self.owner, site)) return error.CustodyNotLocal;
    }
    /// Caller must durably publish this frozen value and retire its resident
    /// before producing or disclosing a signed offer.
    pub fn freeze(self: Custody, site: Site, intent: Intent) !Custody {
        try self.requireLocal(site);
        if (!std.meta.eql(intent.source, site) or std.meta.eql(intent.destination, site) or
            !std.meta.eql(intent.subject, Subject{ .task = self.task, .work = self.work }) or intent.epoch != self.epoch or
            self.epoch == std.math.maxInt(u64)) return error.InvalidTransfer;
        var result = self;
        result.phase = .frozen;
        result.intent = intent;
        result.offer = null;
        result.decision = null;
        return result;
    }
    pub fn offered(self: Custody, a: std.mem.Allocator, signed: Signed(Offer)) !Custody {
        if (self.phase != .frozen or self.intent == null or !std.meta.eql(self.intent.?, signed.value.intent)) return error.InvalidTransfer;
        try verify(Offer, a, signed, self.owner);
        if (self.offer) |prior| if (!std.meta.eql(prior, signed)) return error.OperationConflict;
        var result = self;
        result.offer = signed;
        return result;
    }
    pub fn decided(self: Custody, a: std.mem.Allocator, signed: Signed(Decision)) !Custody {
        const offered_value = self.offer orelse return error.InvalidTransfer;
        try matchDecision(a, offered_value.value, signed);
        if (self.decision) |prior| {
            if (!std.meta.eql(prior, signed)) return error.OperationConflict;
            return self;
        }
        if (self.phase != .frozen) return error.CustodyNotLocal;
        var result = self;
        result.decision = signed;
        switch (signed.value.verdict) {
            .accepted => {
                result.phase = .away;
                result.owner = signed.value.destination;
                result.epoch = signed.value.epoch;
            },
            .refused => result.phase = .local,
        }
        return result;
    }
};
pub fn matchDecision(a: std.mem.Allocator, offer: Offer, signed: Signed(Decision)) !void {
    try verify(Decision, a, signed, offer.intent.destination);
    const value = signed.value;
    if (offer.intent.epoch == std.math.maxInt(u64) or value.epoch != offer.intent.epoch + 1 or
        !std.meta.eql(value.transfer, offer.intent.transfer) or !std.meta.eql(value.source, offer.intent.source) or
        !std.meta.eql(value.offer_digest, try digest(Offer, a, offer))) return error.InvalidTransfer;
}
/// This candidate is not executable until the enclosing native transaction
/// commits both its independently validated objects and this exact decision.
pub fn accept(a: std.mem.Allocator, site: Site, imported: Custody, offer: Signed(Offer), decision: Signed(Decision)) !Custody {
    try verify(Offer, a, offer, offer.value.intent.source);
    try matchDecision(a, offer.value, decision);
    if (!std.meta.eql(site, offer.value.intent.destination) or decision.value.verdict != .accepted or
        imported.phase != .frozen or imported.intent == null or
        !std.meta.eql(imported.intent.?, offer.value.intent) or
        !std.meta.eql(imported.owner, offer.value.intent.source) or imported.epoch != offer.value.intent.epoch or
        !std.meta.eql(imported.id, subjectId(offer.value.intent.subject)) or
        !std.meta.eql(imported.task, offer.value.intent.subject.task) or !std.meta.eql(imported.work, offer.value.intent.subject.work)) return error.InvalidTransfer;
    var result = imported;
    result.phase = .local;
    result.owner = site;
    result.epoch = decision.value.epoch;
    result.offer = offer;
    result.decision = decision;
    return result;
}

test "bilateral placement freezes across lost acceptance and binds namespace, cut and disposition" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |cancelled| {
        for ([_]bool{ false, true }) |parked| {
            for ([_]bool{ false, true }) |settled| {
                const observed: WorkState = .{ .observed_at = 1, .execution_revision = 1, .control_revision = 1, .outcome = .requested, .cleanup_complete = false, .cancellation = if (cancelled) .{ .bytes = "stop" } else null, .explicitly_parked = parked, .park_complete = settled };
                try std.testing.expectEqual(!cancelled and parked and settled, observed.parkSettled());
            }
        }
    }
    const source_key = try Ed25519.KeyPair.generateDeterministic(@splat(1));
    const destination_key = try Ed25519.KeyPair.generateDeterministic(@splat(2));
    const source: Site = .{ .key = source_key.public_key.toBytes(), .namespace = @splat(3) };
    const destination: Site = .{ .key = destination_key.public_key.toBytes(), .namespace = @splat(4) };
    const intent: Intent = .{
        .transfer = @splat(5),
        .subject = .{ .task = @splat(6), .work = @splat(7) },
        .source = source,
        .destination = destination,
        .source_native = @splat(21),
        .destination_native = @splat(22),
        .epoch = 0,
        .cut = .{ .execution = 8, .control = 9, .realization = 2, .checkpoint = .{ .digest = @splat(10), .bytes = 11 } },
        .compatibility = .{ .base = @splat(12), .admission = @splat(13), .bridge = @splat(14), .semantics = @splat(15), .private_state = @splat(16) },
        .resources = @splat(17),
        .disclosure = @splat(18),
    };
    const initial = Custody.initial(intent.subject, source);
    const frozen = try initial.freeze(source, intent);
    const offer = try sign(Offer, a, source_key, .{ .intent = intent, .archive_digest = @splat(19), .archive_bytes = 20 });
    const offered_value = try frozen.offered(a, offer);
    try std.testing.expectError(error.CustodyNotLocal, offered_value.requireLocal(source));
    const decision = try sign(Decision, a, destination_key, .{ .transfer = intent.transfer, .offer_digest = try digest(Offer, a, offer.value), .source = source, .destination = destination, .epoch = 1, .verdict = .accepted });
    const accepted = try accept(a, destination, frozen, offer, decision);
    try accepted.requireLocal(destination);
    // Destination acceptance does not release a source whose reply was lost.
    try std.testing.expectError(error.CustodyNotLocal, offered_value.requireLocal(source));
    const departed = try offered_value.decided(a, decision);
    try std.testing.expectError(error.CustodyNotLocal, departed.requireLocal(source));
    try std.testing.expectEqualDeep(departed, try departed.decided(a, decision));
    var another_namespace = destination;
    another_namespace.namespace[0] ^= 1;
    try std.testing.expectError(error.InvalidTransfer, accept(a, another_namespace, frozen, offer, decision));
    var changed_offer = offer;
    changed_offer.value.intent.cut.execution += 1;
    try std.testing.expectError(error.SignatureVerificationFailed, verify(Offer, a, changed_offer, source));
    var refusal_value = decision.value;
    refusal_value.verdict = .{ .refused = .capacity };
    const refusal = try sign(Decision, a, destination_key, refusal_value);
    try std.testing.expectError(error.OperationConflict, departed.decided(a, refusal));
    const returned = try offered_value.decided(a, refusal);
    try returned.requireLocal(source);
    try std.testing.expectError(error.OperationConflict, returned.decided(a, decision));
    var stale = decision.value;
    stale.epoch += 1;
    try std.testing.expectError(error.InvalidTransfer, matchDecision(a, offer.value, try sign(Decision, a, destination_key, stale)));
}
