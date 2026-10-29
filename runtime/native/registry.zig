//! Static compiled adapters. Requests must match identity, both canonical
//! schemas, and a current launch/task grant before adapter code can run.
const std = @import("std");
const data = @import("horos_data");
const contracts = @import("protean_contracts");
const values = @import("values.zig");
const json = @import("json.zig");
const state = @import("state.zig");
pub const ObjectReference = state.Reference;

/// Read-only projection interface. Generic readers cannot establish retention
/// custody: every projection must validate its complete context closure. Native
/// readers are borrowed only for the duration of Store.project; neither kind
/// may escape the projection call. The representation is private to its owners.
pub const ReadView = struct {
    source: *anyopaque,
    read_object: *const fn (*anyopaque, std.mem.Allocator, state.Reference, usize) anyerror![]u8,
    /// Store-owned scoped capability; never supplied by a generic reader.
    native_scope: ?*anyopaque = null,

    pub fn validating(
        source: *anyopaque,
        read_object: *const fn (
            *anyopaque,
            std.mem.Allocator,
            state.Reference,
            usize,
        ) anyerror![]u8,
    ) ReadView {
        return .{ .source = source, .read_object = read_object };
    }

    pub fn object(self: ReadView, a: std.mem.Allocator, ref: state.Reference, limit: usize) ![]u8 {
        return self.read_object(self.source, a, ref, limit);
    }

    pub fn context(
        self: ReadView,
        comptime P: type,
        ctx: ProjectionContext,
        reference: anytype,
        audience: []const u8,
        catalog: P.AdaptiveCatalog,
        reader: *@import("adaptive_history.zig").History(P).Reader,
    ) !*@import("adaptive_context.zig").Projection(P).ValidatedContext {
        return @import("store.zig").Store.validateContext(
            P,
            self.native_scope,
            ctx,
            reference,
            audience,
            catalog,
            reader,
        );
    }

    pub fn historyRead(self: ReadView, bytes: usize) void {
        if (self.native_scope) |source| @import("store.zig").Store.recordHistoryRead(source, bytes);
    }
};

pub const ControllerProjection = struct {
    binding: state.Digest,
    epoch: u64,
    program: state.Digest,
    overlay: state.Reference,
};
pub const TrialProjection = struct { work: state.Digest, view: state.Reference };
pub const ProjectionBinding = struct {
    task: state.TaskId,
    tenant: []const u8,
    profile: []const u8,
    application: state.Digest,
    resources: []const ObjectReference = &.{},
    controller: ?ControllerProjection = null,
    trial: ?TrialProjection = null,
    execution: ?state.Digest = null,
};

/// Pure projection inputs: immutable objects and frozen task bindings, with no
/// I/O, credentials, evaluator, or mutable store supplied to adapter code.
pub const ProjectionContext = struct {
    allocator: std.mem.Allocator,
    task: state.TaskId,
    tenant: []const u8,
    profile: []const u8,
    application: ?state.Digest = null,
    resources: []const ObjectReference = &.{},
    controller: ?ControllerProjection = null,
    trial: ?TrialProjection = null,
    execution: ?state.Digest = null,
    objects: ReadView,

    pub fn object(self: ProjectionContext, ref: state.Reference, limit: usize) ![]u8 {
        return self.objects.object(self.allocator, ref, limit);
    }
};
pub const Projection = struct {
    reply: []const u8,
    /// Immutable replay artifacts are committed atomically with the reply.
    objects: []const []const u8 = &.{},
    output_tokens: ?u64 = null,
};
/// Pure, registered codec output. These edges are derived from decoded object
/// types by the selected adapter; projection callers cannot attach edge claims.
pub const Dependency = struct { parent: ObjectReference, child: ObjectReference };
pub const DependencyDecoder = *const fn (
    std.mem.Allocator,
    []const []const u8,
) anyerror![]Dependency;
pub const ProjectionReferences = struct {
    allocator: std.mem.Allocator,
    edges: std.ArrayList(Dependency) = .empty,

    pub fn deinit(self: *ProjectionReferences) void {
        self.edges.deinit(self.allocator);
    }
    pub fn object(
        self: *ProjectionReferences,
        comptime T: type,
        comptime Ref: type,
        bytes: []const u8,
        comptime identity: ?[]const u8,
    ) !void {
        var decoded = try contracts.decodeOwned(T, self.allocator, bytes);
        defer decoded.deinit();
        if (identity) |expected| if (!std.mem.eql(
            u8,
            decoded.value.schema.bytes,
            expected,
        )) return error.InvalidProjection;
        var sink = struct {
            collector: *ProjectionReferences,
            parent: ObjectReference,
            pub fn add(this: *@This(), child: ObjectReference) !void {
                try this.collector.edges.append(this.collector.allocator, .{
                    .parent = this.parent,
                    .child = child,
                });
            }
            pub fn reply(_: *@This(), _: @import("occurrence.zig").Acquired) !void {
                @compileError("host occurrence replies require the host dependency codec");
            }
            pub fn observerSource(_: *@This(), _: state.Reference) !void {
                @compileError("host observer evidence requires the host dependency codec");
            }
        }{ .collector = self, .parent = .{
            .digest = @import("store.zig").digest(bytes),
            .bytes = bytes.len,
        } };
        try state.visitReferencesAs(T, Ref, decoded.value, &sink);
    }
    pub fn finish(self: *ProjectionReferences) ![]Dependency {
        return self.edges.toOwnedSlice(self.allocator);
    }
};
/// Explicit registration for a projection whose objects contain no references.
pub fn opaqueProjection(_: std.mem.Allocator, _: []const []const u8) ![]Dependency {
    return &.{};
}
pub const CaptureAdapter = struct {
    dependencies: DependencyDecoder,
    prepare: *const fn (ProjectionContext, []const u8) anyerror![]u8,
    acquire: *const fn (Context, []const u8) anyerror!Acquisition,
    interpret: *const fn (
        ProjectionContext,
        []const u8,
        []const u8,
        []const u8,
    ) anyerror!Projection,
};
pub const Acquisition = union(enum) {
    captured: []const u8,
    definitely_not_sent: anyerror,
    unknown: anyerror,
};

/// Frozen occurrence inputs supplied by the task owner, never client-provided
/// replacement answers. Logical attempt admission remains the Service's job.
pub const RecoveryInput = struct {
    task: state.TaskId,
    occurrence: state.Digest,
    attempt: state.Digest,
    request_identity: state.Digest,
    request: ObjectReference,
    prepared: ?ObjectReference,
    profile: ObjectReference,
    resources: []const ObjectReference,
    capability: []const u8,
    inference: bool,

    pub fn fromReconciliation(
        item: state.Reconciliation,
        identity: state.Digest,
        inference: bool,
    ) RecoveryInput {
        return .{
            .task = item.task,
            .occurrence = item.occurrence,
            .attempt = item.attempt,
            .request_identity = identity,
            .request = item.request,
            .prepared = item.prepared,
            .profile = item.profile,
            .resources = item.resources.items,
            .capability = item.capability.bytes,
            .inference = inference,
        };
    }
};
/// Worker-owned pure inputs. Object access and projection leases stay with the
/// admission owner; artifact-dependent computations use frozen prepared bytes.
pub const RederivationContext = struct {
    allocator: std.mem.Allocator,
    task: state.TaskId,
    profile: []const u8,
    cancellation: *const std.atomic.Value(bool),

    pub fn checkCancellation(self: RederivationContext) !void {
        if (self.cancellation.load(.acquire)) return error.Canceled;
    }
};
pub const RederivationFinding = union(enum) {
    result: []const u8,
    unsupported,
    unavailable,
    inconclusive,
    rejected,
};
pub const RecoveryFinding = union(enum) {
    /// Exact historical bytes authenticated by the compiled verifier.
    capture: []const u8,
    not_sent,
    inconclusive,
    unavailable,
    rejected,
};
pub const ReceiptLookup = struct {
    /// Read-only authoritative receipt retrieval. This callback must never
    /// invoke the original effect. Native adapters remain trusted code.
    /// Return complete receipt/proof bytes. Ancillary verifier inputs must be
    /// in the original frozen resource closure, so evidence is archive-complete.
    acquire: *const fn (Context, RecoveryInput, []const u8, ?[]const u8) anyerror![]u8,
    /// The owner verifies returned evidence under the original immutable
    /// bindings before any occurrence transition. Neither callback has Store.
    /// Semantic non-results are explicit RecoveryFinding values. Errors mean
    /// verification failed operationally and must not finalize reconciliation.
    verify: *const fn (ProjectionContext, RecoveryInput, []const u8) anyerror!RecoveryFinding,
};
pub const RecoveryAdapter = struct {
    identity: []const u8,
    version: u32,
    /// Pure worker computation over the admitted request and prepared bytes.
    /// No projection reader, IO, credentials, or environment handle escapes.
    /// Non-results are explicit; errors remain operational failures. Cancellation
    /// interrupts this new computation without resolving historical delivery.
    rederive: ?*const fn (
        RederivationContext,
        RecoveryInput,
        []const u8,
        ?[]const u8,
    ) anyerror!RederivationFinding = null,
    lookup: ?ReceiptLookup = null,
};

pub const Grant = struct {
    identity: []const u8,
    resource_role: []const u8,
    /// Exact application, frozen profile and ordered immutable resource set.
    resource_identity: [32]u8,
};

pub fn resourceIdentity(image: [32]u8, profile: [32]u8, resources: []const ObjectReference) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("agent.native.resources.v1\x00");
    hash.update(&image);
    hash.update(&profile);
    var count: [8]u8 = undefined;
    std.mem.writeInt(u64, &count, resources.len, .little);
    hash.update(&count);
    for (resources) |resource| {
        hash.update(&resource.digest);
        std.mem.writeInt(u64, &count, resource.bytes, .little);
        hash.update(&count);
    }
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}
pub const Authority = struct {
    grants: []const Grant,
    principal: []const u8,
    tenant: []const u8,
    inference: bool = false,
    revoked: bool = false,
    disclosure: bool = true,
};
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    authority: *const Authority,
    task_id: []const u8,
    profile: []const u8,
    /// Application/environment handles only; no evaluator handle is supplied.
    environment: ?*anyopaque,
    cancellation: ?*const std.atomic.Value(bool) = null,
    pub fn checkCancellation(self: Context) error{Canceled}!void {
        if (self.cancellation) |flag| if (flag.load(.acquire)) return error.Canceled;
    }
};
pub const Kind = enum { leaf, question, inbox, workspace };
pub const Declaration = struct {
    identity: []const u8,
    resource_role: []const u8,
    kind: Kind,
    /// Registered for owner-created workspace images, not the root image.
    workspace_only: bool = false,
    controller_import: ?contracts.controller.Import = null,
    controller_offer: ?*const fn (ProjectionContext, []const u8) anyerror![]u8 = null,
    controller_choice: ?*const fn (
        ProjectionContext,
        []const u8,
    ) anyerror!?contracts.workspace.Adoption = null,
    controller_permission: ?*const fn (ProjectionContext) anyerror!bool = null,
    inference: bool = false,
    /// Only this adapter's committed projection objects are public task data.
    /// Raw captures, prepared requests and other adapters' objects stay private.
    public_outputs: bool = false,
    background: bool = false,
    /// acquire receives prepared bytes and returns an uninterpreted capture.
    capture: ?CaptureAdapter = null,
    recovery: ?RecoveryAdapter = null,
    payload_schema: *const fn (std.mem.Allocator) anyerror![]u8,
    resume_schema: *const fn (std.mem.Allocator) anyerror![]u8,
    invoke: ?*const fn (Context, []const u8) anyerror![]u8 = null,
    present: ?*const fn (Context, []const u8) anyerror!json.Value = null,
    answer: ?*const fn (std.mem.Allocator, json.Value) anyerror![]u8 = null,
    answer_schema_id: ?[]const u8 = null,
    /// Authenticate a direct model action using immutable projection inputs.
    /// The native owner alone interprets the resulting workspace command.
    workspace: ?*const fn (ProjectionContext, []const u8) anyerror![]u8 = null,
};
pub const Entry = struct {
    declaration: Declaration,
    payload_schema: []const u8,
    resume_schema: []const u8,
    controller_envelope: bool = false,

    pub fn payload(self: Entry, a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
        if (!self.controller_envelope) return bytes;
        var schema = try data.schema.decode(a, self.payload_schema);
        defer schema.deinit();
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        const facts = try data.admission.schemas(scratch, schema.descriptor.types);
        var reader: data.wire.Reader = .{ .input = bytes };
        _ = try data.admission.readValue(
            scratch,
            schema.descriptor.types,
            facts,
            schema.descriptor.root,
            &reader,
        );
        return bytes[0..reader.position];
    }
};

pub fn controllerImport(
    imported: contracts.controller.Import,
    declaration: Declaration,
) Declaration {
    var bound = declaration;
    bound.controller_import = imported;
    return bound;
}

fn sameBinding(
    entry: Entry,
    identity: []const u8,
    payload: []const u8,
    resume_schema: []const u8,
) bool {
    return std.mem.eql(u8, entry.declaration.identity, identity) and
        std.mem.eql(u8, entry.payload_schema, payload) and
        std.mem.eql(u8, entry.resume_schema, resume_schema);
}

fn validateDeclaration(declaration: Declaration) !void {
    if (declaration.identity.len == 0 or
        declaration.resource_role.len == 0)
    {
        return error.InvalidCapability;
    }
    if (declaration.public_outputs and
        declaration.capture == null)
    {
        return error.InvalidCapability;
    }
    if (declaration.kind == .leaf and
        declaration.invoke == null and
        declaration.capture == null)
    {
        return error.InvalidCapability;
    }
    if (declaration.capture != null and
        (declaration.kind != .leaf or
            !declaration.background or
            declaration.invoke != null))
    {
        return error.InvalidCapability;
    }
    if (declaration.recovery) |recovery| {
        if (declaration.kind != .leaf or
            recovery.identity.len == 0 or
            recovery.version == 0 or
            (recovery.rederive == null and
                recovery.lookup == null))
        {
            return error.InvalidCapability;
        }
    }
    if (declaration.kind == .question and
        (declaration.present == null or
            declaration.answer == null or
            declaration.answer_schema_id == null))
    {
        return error.InvalidCapability;
    }
    if ((declaration.kind == .workspace) != (declaration.workspace != null)) {
        return error.InvalidCapability;
    }
}

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,

    pub fn init(a: std.mem.Allocator, declarations: []const Declaration) !Registry {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const storage = arena.allocator();
        const entries = try storage.alloc(Entry, declarations.len);
        for (declarations, entries, 0..) |declaration, *entry, i| {
            try validateDeclaration(declaration);
            entry.* = .{
                .declaration = declaration,
                .payload_schema = try declaration.payload_schema(storage),
                .resume_schema = try declaration.resume_schema(storage),
            };
            // A request names its exact schemas, but has no independent role
            // selector. Indistinguishable bindings must never depend on order.
            for (entries[0..i]) |prior| {
                if (sameBinding(
                    prior,
                    declaration.identity,
                    entry.payload_schema,
                    entry.resume_schema,
                )) return error.DuplicateCapability;
                if (declaration.controller_import != null and
                    prior.declaration.controller_import == declaration.controller_import)
                {
                    return error.DuplicateCapability;
                }
            }
        }
        return .{ .arena = arena, .entries = entries };
    }
    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn admit(
        self: Registry,
        request: data.invocation.Request,
        authority: Authority,
        image_identity: [32]u8,
        resource_identity: [32]u8,
    ) !Entry {
        if (authority.revoked) return error.Denied;
        const entry = try self.resolve(request, image_identity);
        const declaration = entry.declaration;
        if (declaration.inference and !authority.inference) return error.Denied;
        for (authority.grants) |grant| {
            if (std.mem.eql(u8, grant.identity, declaration.identity) and
                std.mem.eql(u8, grant.resource_role, declaration.resource_role) and
                std.mem.eql(u8, &grant.resource_identity, &resource_identity)) return entry;
        }
        return error.Denied;
    }

    /// Schema/identity resolution does not authorize fresh I/O. Recovery uses
    /// this path to consume a saved reply without requiring a new spend grant.
    pub fn resolve(
        self: Registry,
        request: data.invocation.Request,
        image_identity: [32]u8,
    ) !Entry {
        if (!std.mem.eql(
            u8,
            &request.binding.program_identity,
            &image_identity,
        )) return error.Denied;
        if (std.mem.startsWith(
            u8,
            request.binding.semantic_identity,
            contracts.controller.effect_prefix,
        )) {
            return self.resolveController(request);
        }
        var known_identity = false;
        for (self.entries) |entry| {
            if (!std.mem.eql(
                u8,
                request.binding.semantic_identity,
                entry.declaration.identity,
            )) continue;
            known_identity = true;
            if (sameBinding(
                entry,
                request.binding.semantic_identity,
                request.binding.payload_schema,
                request.binding.resume_schema,
            )) return entry;
        }
        return if (known_identity) error.CapabilitySchemaMismatch else error.MissingCapability;
    }

    fn resolveController(self: Registry, request: data.invocation.Request) !Entry {
        const imported = std.meta.stringToEnum(
            contracts.controller.Import,
            request.binding.semantic_identity[contracts.controller.effect_prefix.len..],
        ) orelse return error.MissingCapability;
        for (self.entries) |entry| {
            if (entry.declaration.controller_import != imported) continue;
            if (!std.mem.eql(
                u8,
                entry.resume_schema,
                request.binding.resume_schema,
            )) return error.CapabilitySchemaMismatch;
            if (imported != .deliberate) {
                if (!std.mem.eql(
                    u8,
                    entry.payload_schema,
                    request.binding.payload_schema,
                )) return error.CapabilitySchemaMismatch;
                return entry;
            }
            const a = self.arena.child_allocator;
            var schema = try data.schema.decode(a, request.binding.payload_schema);
            defer schema.deinit();
            const root = schema.descriptor.types[@intCast(schema.descriptor.root)];
            if (root != .product or
                root.product.len != 2)
            {
                return error.CapabilitySchemaMismatch;
            }
            const payload_schema = try data.schema.encodeOwned(
                a,
                schema.descriptor.types,
                root.product[0],
            );
            defer a.free(payload_schema);
            if (!std.mem.eql(
                u8,
                entry.payload_schema,
                payload_schema,
            )) return error.CapabilitySchemaMismatch;
            var bound = entry;
            bound.controller_envelope = true;
            return bound;
        }
        return error.MissingCapability;
    }

    /// Validate frozen inputs before durable recovery admission. Computation
    /// runs later on the worker, after this borrowed projection view expires.
    pub fn validateRederivation(
        self: Registry,
        ctx: ProjectionContext,
        input: RecoveryInput,
    ) !void {
        return self.recover(false, ctx, input, null);
    }
    pub fn verifyRecovery(
        self: Registry,
        ctx: ProjectionContext,
        input: RecoveryInput,
        evidence: []const u8,
    ) !RecoveryFinding {
        return self.recover(true, ctx, input, evidence);
    }
    fn recover(
        self: Registry,
        comptime lookup: bool,
        ctx: ProjectionContext,
        input: RecoveryInput,
        evidence: ?[]const u8,
    ) !(if (lookup) RecoveryFinding else void) {
        const image = ctx.execution orelse ctx.application orelse return error.InvalidRecovery;
        if (!std.meta.eql(ctx.task, input.task) or input.profile.bytes != ctx.profile.len or
            !std.meta.eql(input.profile.digest, @import("store.zig").digest(ctx.profile)) or
            !std.meta.eql(ctx.resources.len, input.resources.len)) return error.InvalidRecovery;
        for (ctx.resources, input.resources) |actual, expected| if (!std.meta.eql(
            actual,
            expected,
        )) return error.InvalidRecovery;
        const request_bytes = try recoveryObject(ctx, input.request);
        defer ctx.allocator.free(request_bytes);
        var request = try data.invocation.decode(
            data.invocation.Request,
            ctx.allocator,
            request_bytes,
        );
        defer request.deinit();
        if (!std.meta.eql(
            request.value.request_identity,
            input.request_identity,
        )) return error.InvalidRecovery;
        const entry = try self.resolve(request.value, image);
        if (!std.mem.eql(
            u8,
            input.capability,
            entry.declaration.identity,
        ) or input.inference != entry.declaration.inference) return error.InvalidRecovery;
        const adapter = entry.declaration.recovery orelse return error.UnsupportedRecovery;
        const prepared = if (input.prepared) |ref| try recoveryObject(ctx, ref) else null;
        defer if (prepared) |bytes| ctx.allocator.free(bytes);
        if (entry.declaration.capture) |capture| {
            const original = prepared orelse return error.InvalidRecovery;
            const derived = try capture.prepare(
                ctx,
                try entry.payload(ctx.allocator, request.value.binding.payload),
            );
            defer ctx.allocator.free(derived);
            if (!std.mem.eql(u8, original, derived)) return error.InvalidPreparedRequest;
        } else if (prepared != null) return error.InvalidRecovery;
        if (lookup) {
            const verifier = adapter.lookup orelse return error.UnsupportedRecovery;
            const result = try verifier.verify(ctx, input, evidence.?);
            if (result == .capture and
                entry.declaration.capture == null)
            {
                return error.InvalidRecovery;
            }
            return result;
        }
        if (adapter.rederive == null) return error.UnsupportedRecovery;
    }
};

fn recoveryObject(ctx: ProjectionContext, ref: ObjectReference) ![]u8 {
    const bytes = try ctx.object(ref, std.math.cast(usize, ref.bytes) orelse return error.Capacity);
    errdefer ctx.allocator.free(bytes);
    if (bytes.len != ref.bytes or !std.meta.eql(
        @import("store.zig").digest(bytes),
        ref.digest,
    )) return error.InvalidRecovery;
    return bytes;
}

pub fn leaf(comptime Payload: type, comptime Reply: type, comptime options: struct {
    identity: []const u8,
    resource_role: []const u8,
    inference: bool = false,
    background: bool = false,
}, comptime handle: fn (Context, Payload) anyerror!Reply) Declaration {
    return .{
        .identity = options.identity,
        .resource_role = options.resource_role,
        .kind = .leaf,
        .inference = options.inference,
        .background = options.background,
        .payload_schema = struct {
            fn schema(a: std.mem.Allocator) ![]u8 {
                return values.schemaBytes(Payload, a);
            }
        }.schema,
        .resume_schema = struct {
            fn schema(a: std.mem.Allocator) ![]u8 {
                return values.schemaBytes(Reply, a);
            }
        }.schema,
        .invoke = struct {
            fn invoke(ctx: Context, bytes: []const u8) ![]u8 {
                var payload = try contracts.decodeOwned(Payload, ctx.allocator, bytes);
                defer payload.deinit();
                const result = try handle(ctx, payload.value);
                return contracts.encodeOwned(Reply, ctx.allocator, result);
            }
        }.invoke,
    };
}

pub fn question(comptime Payload: type, comptime Answer: type, comptime options: struct {
    identity: []const u8,
    resource_role: []const u8,
    answer_schema_id: []const u8,
}, comptime present: fn (Context, Payload) anyerror!json.Value) Declaration {
    return .{
        .identity = options.identity,
        .resource_role = options.resource_role,
        .kind = .question,
        .answer_schema_id = options.answer_schema_id,
        .payload_schema = struct {
            fn schema(a: std.mem.Allocator) ![]u8 {
                return values.schemaBytes(Payload, a);
            }
        }.schema,
        .resume_schema = struct {
            fn schema(a: std.mem.Allocator) ![]u8 {
                return values.schemaBytes(Answer, a);
            }
        }.schema,
        .present = struct {
            fn call(ctx: Context, bytes: []const u8) !json.Value {
                var payload = try contracts.decodeOwned(Payload, ctx.allocator, bytes);
                defer payload.deinit();
                // Presentation may borrow its input, so retain it in the
                // caller's arena by round-tripping the bounded JSON value.
                const shown = try present(ctx, payload.value);
                const encoded = try json.canonical(ctx.allocator, shown);
                return std.json.parseFromSliceLeaky(json.Value, ctx.allocator, encoded, .{
                    .allocate = .alloc_always,
                    .parse_numbers = false,
                });
            }
        }.call,
        .answer = struct {
            fn encode(a: std.mem.Allocator, value: json.Value) ![]u8 {
                return values.encodeClient(Answer, a, value);
            }
        }.encode,
    };
}

test "capability admission requires the complete schema and current resource grant" {
    const a = std.testing.allocator;
    const increment = struct {
        fn run(_: Context, input: u32) !u32 {
            return std.math.add(u32, input, 1);
        }
    }.run;
    var registry = try Registry.init(a, &.{
        leaf(u32, u32, .{ .identity = "increment.v1", .resource_role = "local" }, increment),
    });
    defer registry.deinit();
    const entry = registry.entries[0];
    const binding: data.invocation.Binding = .{
        .program_identity = @splat(1),
        .pending_state_digest = @splat(2),
        .effect = 0,
        .semantic_identity = "increment.v1",
        .payload_schema = entry.payload_schema,
        .resume_schema = entry.resume_schema,
        .payload = &.{ 1, 0, 0, 0 },
    };
    const request = try data.invocation.request(binding);
    const resources: []const ObjectReference = &.{.{ .digest = @splat(3), .bytes = 17 }};
    const resource = resourceIdentity(@splat(1), @splat(2), resources);
    const authority: Authority = .{ .principal = "test", .tenant = "test", .grants = &.{.{
        .identity = "increment.v1",
        .resource_role = "local",
        .resource_identity = resource,
    }} };
    _ = try registry.admit(request, authority, @splat(1), resource);
    for ([_][32]u8{
        resourceIdentity(@splat(1), @splat(4), resources),
        resourceIdentity(@splat(1), @splat(2), &.{.{ .digest = @splat(5), .bytes = 17 }}),
    }) |other| try std.testing.expectError(
        error.Denied,
        registry.admit(request, authority, @splat(1), other),
    );
    var disabled = authority;
    disabled.grants = &.{};
    try std.testing.expectError(
        error.Denied,
        registry.admit(request, disabled, @splat(1), resource),
    );
    disabled = authority;
    disabled.revoked = true;
    try std.testing.expectError(
        error.Denied,
        registry.admit(request, disabled, @splat(1), resource),
    );
    var wrong = request;
    wrong.binding.resume_schema = &.{};
    try std.testing.expectError(
        error.CapabilitySchemaMismatch,
        registry.admit(wrong, authority, @splat(1), resource),
    );
}

test "pure recovery admission binds frozen inputs without computation or invocation" {
    const a = std.testing.allocator;
    const storage = @import("store.zig");
    const Handler = struct {
        fn invoke(_: Context, _: u32) !u32 {
            return error.EnvironmentMustNotRun;
        }
        fn rederive(
            _: RederivationContext,
            _: RecoveryInput,
            _: []const u8,
            _: ?[]const u8,
        ) !RederivationFinding {
            return error.ComputationMustWaitForWorker;
        }
    };
    var declaration = leaf(
        u32,
        u32,
        .{ .identity = "pure-increment.v1", .resource_role = "frozen" },
        Handler.invoke,
    );
    declaration.recovery = .{
        .identity = "pure-increment.recovery.v1",
        .version = 1,
        .rederive = Handler.rederive,
    };
    var registry = try Registry.init(a, &.{declaration});
    defer registry.deinit();
    const entry = registry.entries[0];
    const request = try data.invocation.request(.{
        .program_identity = @splat(1),
        .pending_state_digest = @splat(2),
        .effect = 0,
        .semantic_identity = declaration.identity,
        .payload_schema = entry.payload_schema,
        .resume_schema = entry.resume_schema,
        .payload = &.{ 7, 0, 0, 0 },
    });
    const encoded = try data.invocation.encodeOwned(data.invocation.Request, a, request);
    defer a.free(encoded);
    var object = struct {
        bytes: []const u8,
        fn read(
            pointer: *anyopaque,
            allocator: std.mem.Allocator,
            _: ObjectReference,
            _: usize,
        ) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(pointer));
            return allocator.dupe(u8, self.bytes);
        }
    }{ .bytes = encoded };
    const resources: []const ObjectReference = &.{
        .{ .digest = @splat(3), .bytes = 17 },
        .{ .digest = @splat(4), .bytes = 19 },
    };
    const ctx: ProjectionContext = .{
        .allocator = a,
        .task = @splat(9),
        .tenant = "test",
        .profile = "frozen profile",
        .application = @splat(1),
        .resources = resources,
        .objects = .validating(&object, @TypeOf(object).read),
    };
    const original: RecoveryInput = .{
        .task = ctx.task,
        .occurrence = @splat(5),
        .attempt = @splat(6),
        .request_identity = request.request_identity,
        .request = .{ .digest = storage.digest(encoded), .bytes = encoded.len },
        .prepared = null,
        .profile = .{ .digest = storage.digest(ctx.profile), .bytes = ctx.profile.len },
        .resources = resources,
        .capability = declaration.identity,
        .inference = false,
    };
    try expectRecoveryRejections(registry, ctx, original);
}

test "schema-specialized capability families resolve independently of declaration order" {
    const a = std.testing.allocator;
    const Handler = struct {
        fn small(_: Context, value: u32) !u32 {
            return value;
        }
        fn large(_: Context, value: u64) !u64 {
            return value;
        }
    };
    const small = leaf(
        u32,
        u32,
        .{ .identity = "model-family", .resource_role = "small" },
        Handler.small,
    );
    const large = leaf(
        u64,
        u64,
        .{ .identity = "model-family", .resource_role = "large" },
        Handler.large,
    );
    try std.testing.expectError(error.DuplicateCapability, Registry.init(a, &.{ small, small }));
    var distinct_large = large;
    distinct_large.identity = "other-family";
    for ([_][2]Declaration{
        .{ small, large },
        .{ large, small },
        .{ small, distinct_large },
        .{ distinct_large, small },
    }) |declarations| {
        var registry = try Registry.init(a, &declarations);
        defer registry.deinit();
        for (registry.entries) |entry| try expectFamilyBinding(registry, entry);
    }
}

fn expectRecoveryRejections(
    registry: Registry,
    ctx: ProjectionContext,
    original: RecoveryInput,
) !void {
    try registry.validateRederivation(ctx, original);
    for (0..7) |case| {
        var input = original;
        switch (case) {
            0 => input.task[0] ^= 1,
            1 => input.profile.digest[0] ^= 1,
            2 => input.profile.bytes += 1,
            3 => input.resources = &.{ original.resources[1], original.resources[0] },
            4 => input.request_identity[0] ^= 1,
            5 => input.request.digest[0] ^= 1,
            6 => input.inference = true,
            else => unreachable,
        }
        try std.testing.expectError(
            error.InvalidRecovery,
            registry.validateRederivation(ctx, input),
        );
    }
    var foreign = ctx;
    foreign.application = @splat(7);
    try std.testing.expectError(error.Denied, registry.validateRederivation(foreign, original));
}

fn expectFamilyBinding(registry: Registry, entry: Entry) !void {
    const input: [8]u8 = @splat(0);
    const length: usize = if (std.mem.eql(
        u8,
        entry.declaration.resource_role,
        "small",
    )) 4 else 8;
    const request = try data.invocation.request(.{
        .program_identity = @splat(1),
        .pending_state_digest = @splat(2),
        .effect = 0,
        .semantic_identity = entry.declaration.identity,
        .payload_schema = entry.payload_schema,
        .resume_schema = entry.resume_schema,
        .payload = input[0..length],
    });
    const resolved = try registry.resolve(request, @splat(1));
    try std.testing.expectEqualStrings(
        entry.declaration.resource_role,
        resolved.declaration.resource_role,
    );
    const authority: Authority = .{ .principal = "test", .tenant = "test", .grants = &.{.{
        .identity = entry.declaration.identity,
        .resource_role = entry.declaration.resource_role,
        .resource_identity = @splat(3),
    }} };
    _ = try registry.admit(request, authority, @splat(1), @splat(3));
    var denied = authority;
    denied.grants = &.{.{
        .identity = entry.declaration.identity,
        .resource_role = "unrelated",
        .resource_identity = @splat(3),
    }};
    try std.testing.expectError(
        error.Denied,
        registry.admit(request, denied, @splat(1), @splat(3)),
    );
    var wrong = request;
    wrong.binding.payload_schema = "unknown";
    try std.testing.expectError(
        error.CapabilitySchemaMismatch,
        registry.resolve(wrong, @splat(1)),
    );
}
