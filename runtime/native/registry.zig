//! Static compiled adapters. Requests must match identity, both canonical
//! schemas, and a current launch/task grant before adapter code can run.
const std = @import("std");
const data = @import("horos_data");
const contracts = @import("protean_contracts");
const values = @import("values.zig");
const json = @import("json.zig");
const state = @import("state.zig");
pub const ObjectReference = state.Reference;

/// Pure projection inputs: immutable objects and frozen task bindings, with no
/// I/O, credentials, evaluator, or mutable store supplied to adapter code.
pub const ProjectionContext = struct {
    allocator: std.mem.Allocator,
    task: state.TaskId,
    tenant: []const u8,
    profile: []const u8,
    objects: struct {
        owner: *anyopaque,
        read: *const fn (*anyopaque, std.mem.Allocator, state.Reference, usize) anyerror![]u8,
    },

    pub fn object(self: ProjectionContext, ref: state.Reference, limit: usize) ![]u8 {
        return self.objects.read(self.objects.owner, self.allocator, ref, limit);
    }
};
pub const Projection = struct {
    reply: []const u8,
    /// Immutable replay artifacts are committed atomically with the reply.
    objects: []const []const u8 = &.{},
    output_tokens: ?u64 = null,
};
pub const CaptureAdapter = struct {
    prepare: *const fn (ProjectionContext, []const u8) anyerror![]u8,
    acquire: *const fn (Context, []const u8) anyerror!Acquisition,
    interpret: *const fn (ProjectionContext, []const u8, []const u8, []const u8) anyerror!Projection,
};
pub const Acquisition = union(enum) {
    captured: []const u8,
    definitely_not_sent: anyerror,
    unknown: anyerror,
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
    /// Dispatch-time observation, including the current physical attempt.
    /// This can narrow presentation; only the task owner admits actual work.
    exhausted_capabilities: []const []const u8 = &.{},

    pub fn nextAttemptLimitExhausted(self: Context, identity: []const u8) bool {
        for (self.exhausted_capabilities) |item| if (std.mem.eql(u8, item, identity)) return true;
        return false;
    }

    pub fn checkCancellation(self: Context) error{Canceled}!void {
        if (self.cancellation) |flag| if (flag.load(.acquire)) return error.Canceled;
    }
};
pub const Kind = enum { leaf, question, inbox };
pub const Declaration = struct {
    identity: []const u8,
    resource_role: []const u8,
    kind: Kind,
    inference: bool = false,
    /// A frozen application policy may narrow the host's physical-attempt
    /// ceiling. This is dispatch admission, never capture reinterpretation.
    inference_attempt_limit: ?*const fn (std.mem.Allocator, []const u8) anyerror!u32 = null,
    /// All physical attempts for this identity, including rejected/failed work.
    /// Counted from the existing durable attempt records across restart/import.
    /// Every schema specialization of one identity must use the same limit.
    attempt_limit: ?u32 = null,
    /// Only this adapter's committed projection objects are public task data.
    /// Raw captures, prepared requests and other adapters' objects stay private.
    public_outputs: bool = false,
    background: bool = false,
    /// acquire receives prepared bytes and returns an uninterpreted capture.
    capture: ?CaptureAdapter = null,
    payload_schema: *const fn (std.mem.Allocator) anyerror![]u8,
    resume_schema: *const fn (std.mem.Allocator) anyerror![]u8,
    invoke: ?*const fn (Context, []const u8) anyerror![]u8 = null,
    present: ?*const fn (Context, []const u8) anyerror!json.Value = null,
    answer: ?*const fn (std.mem.Allocator, json.Value) anyerror![]u8 = null,
    answer_schema_id: ?[]const u8 = null,
};
pub const Entry = struct {
    declaration: Declaration,
    payload_schema: []const u8,
    resume_schema: []const u8,
};

fn sameBinding(entry: Entry, identity: []const u8, payload: []const u8, resume_schema: []const u8) bool {
    return std.mem.eql(u8, entry.declaration.identity, identity) and std.mem.eql(u8, entry.payload_schema, payload) and std.mem.eql(u8, entry.resume_schema, resume_schema);
}

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,

    pub fn init(a: std.mem.Allocator, declarations: []const Declaration) !Registry {
        if (declarations.len > 64) return error.Capacity;
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const storage = arena.allocator();
        const entries = try storage.alloc(Entry, declarations.len);
        for (declarations, entries, 0..) |declaration, *entry, i| {
            if (declaration.identity.len == 0 or declaration.resource_role.len == 0) return error.InvalidCapability;
            if (declaration.inference_attempt_limit != null and !declaration.inference) return error.InvalidCapability;
            if (declaration.attempt_limit) |limit| if (limit == 0 or limit > 64 or declaration.kind != .leaf) return error.InvalidCapability;
            if (declaration.public_outputs and declaration.capture == null) return error.InvalidCapability;
            if (declaration.kind == .leaf and declaration.invoke == null and declaration.capture == null) return error.InvalidCapability;
            if (declaration.capture != null and (declaration.kind != .leaf or !declaration.background or declaration.invoke != null)) return error.InvalidCapability;
            if (declaration.kind == .question and (declaration.present == null or declaration.answer == null or declaration.answer_schema_id == null)) return error.InvalidCapability;
            entry.* = .{
                .declaration = declaration,
                .payload_schema = try declaration.payload_schema(storage),
                .resume_schema = try declaration.resume_schema(storage),
            };
            // A request names its exact schemas, but has no independent role
            // selector. Indistinguishable bindings must never depend on order.
            for (entries[0..i]) |prior| {
                if (std.mem.eql(u8, prior.declaration.identity, declaration.identity) and
                    prior.declaration.attempt_limit != declaration.attempt_limit) return error.InvalidCapability;
                if (sameBinding(prior, declaration.identity, entry.payload_schema, entry.resume_schema)) return error.DuplicateCapability;
            }
        }
        return .{ .arena = arena, .entries = entries };
    }
    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn admit(self: Registry, request: data.invocation.Request, authority: Authority, image_identity: [32]u8, resource_identity: [32]u8) !Entry {
        if (authority.revoked) return error.Denied;
        const entry = try self.resolve(request, image_identity);
        const declaration = entry.declaration;
        if (declaration.inference and !authority.inference) return error.Denied;
        for (authority.grants) |grant| {
            if (std.mem.eql(u8, grant.identity, declaration.identity) and std.mem.eql(u8, grant.resource_role, declaration.resource_role) and
                std.mem.eql(u8, &grant.resource_identity, &resource_identity)) return entry;
        }
        return error.Denied;
    }

    /// Schema/identity resolution does not authorize fresh I/O. Recovery uses
    /// this path to consume a saved reply without requiring a new spend grant.
    pub fn resolve(self: Registry, request: data.invocation.Request, image_identity: [32]u8) !Entry {
        if (!std.mem.eql(u8, &request.binding.program_identity, &image_identity)) return error.Denied;
        var known_identity = false;
        for (self.entries) |entry| {
            if (!std.mem.eql(u8, request.binding.semantic_identity, entry.declaration.identity)) continue;
            known_identity = true;
            if (sameBinding(entry, request.binding.semantic_identity, request.binding.payload_schema, request.binding.resume_schema)) return entry;
        }
        return if (known_identity) error.CapabilitySchemaMismatch else error.MissingCapability;
    }
};

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
                return std.json.parseFromSliceLeaky(json.Value, ctx.allocator, encoded, .{ .allocate = .alloc_always, .parse_numbers = false });
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
    var registry = try Registry.init(a, &.{leaf(u32, u32, .{ .identity = "increment.v1", .resource_role = "local" }, increment)});
    defer registry.deinit();
    const entry = registry.entries[0];
    const binding: data.invocation.Binding = .{ .program_identity = @splat(1), .pending_state_digest = @splat(2), .effect = 0, .semantic_identity = "increment.v1", .payload_schema = entry.payload_schema, .resume_schema = entry.resume_schema, .payload = &.{ 1, 0, 0, 0 } };
    const request = try data.invocation.request(binding);
    const resources: []const ObjectReference = &.{.{ .digest = @splat(3), .bytes = 17 }};
    const resource = resourceIdentity(@splat(1), @splat(2), resources);
    const authority: Authority = .{ .principal = "test", .tenant = "test", .grants = &.{.{ .identity = "increment.v1", .resource_role = "local", .resource_identity = resource }} };
    _ = try registry.admit(request, authority, @splat(1), resource);
    for ([_][32]u8{
        resourceIdentity(@splat(1), @splat(4), resources),
        resourceIdentity(@splat(1), @splat(2), &.{.{ .digest = @splat(5), .bytes = 17 }}),
    }) |other| try std.testing.expectError(error.Denied, registry.admit(request, authority, @splat(1), other));
    var disabled = authority;
    disabled.grants = &.{};
    try std.testing.expectError(error.Denied, registry.admit(request, disabled, @splat(1), resource));
    disabled = authority;
    disabled.revoked = true;
    try std.testing.expectError(error.Denied, registry.admit(request, disabled, @splat(1), resource));
    var wrong = request;
    wrong.binding.resume_schema = &.{};
    try std.testing.expectError(error.CapabilitySchemaMismatch, registry.admit(wrong, authority, @splat(1), resource));
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
    const small = leaf(u32, u32, .{ .identity = "model-family", .resource_role = "small" }, Handler.small);
    const large = leaf(u64, u64, .{ .identity = "model-family", .resource_role = "large" }, Handler.large);
    try std.testing.expectError(error.DuplicateCapability, Registry.init(a, &.{ small, small }));
    var limited_small = small;
    limited_small.attempt_limit = 2;
    var limited_large = large;
    limited_large.attempt_limit = 2;
    var distinct_large = large;
    distinct_large.identity = "other-family";
    distinct_large.attempt_limit = 3;
    // Shared accounting requires a single policy for the entire identity;
    // neither declaration order nor a different schema can select a new budget.
    for ([_]?u32{ null, 1, 3 }) |limit| {
        var conflicting = large;
        conflicting.attempt_limit = limit;
        try std.testing.expectError(error.InvalidCapability, Registry.init(a, &.{ limited_small, conflicting }));
        try std.testing.expectError(error.InvalidCapability, Registry.init(a, &.{ conflicting, limited_small }));
    }
    for ([_][2]Declaration{ .{ small, large }, .{ large, small }, .{ limited_small, limited_large }, .{ limited_large, limited_small }, .{ limited_small, distinct_large }, .{ distinct_large, limited_small } }) |declarations| {
        var registry = try Registry.init(a, &declarations);
        defer registry.deinit();
        for (registry.entries) |entry| {
            const input: [8]u8 = @splat(0);
            const length: usize = if (std.mem.eql(u8, entry.declaration.resource_role, "small")) 4 else 8;
            const request = try data.invocation.request(.{ .program_identity = @splat(1), .pending_state_digest = @splat(2), .effect = 0, .semantic_identity = entry.declaration.identity, .payload_schema = entry.payload_schema, .resume_schema = entry.resume_schema, .payload = input[0..length] });
            const resolved = try registry.resolve(request, @splat(1));
            try std.testing.expectEqualStrings(entry.declaration.resource_role, resolved.declaration.resource_role);
            const authority: Authority = .{ .principal = "test", .tenant = "test", .grants = &.{.{ .identity = entry.declaration.identity, .resource_role = entry.declaration.resource_role, .resource_identity = @splat(3) }} };
            _ = try registry.admit(request, authority, @splat(1), @splat(3));
            var denied = authority;
            denied.grants = &.{.{ .identity = entry.declaration.identity, .resource_role = "unrelated", .resource_identity = @splat(3) }};
            try std.testing.expectError(error.Denied, registry.admit(request, denied, @splat(1), @splat(3)));
            var wrong = request;
            wrong.binding.payload_schema = "unknown";
            try std.testing.expectError(error.CapabilitySchemaMismatch, registry.resolve(wrong, @splat(1)));
        }
    }
}
