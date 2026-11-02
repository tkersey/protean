const std = @import("std");
const registry = @import("registry.zig");
const state = @import("state.zig");

pub const Action = enum { read, retain, import };

pub const Scope = struct {
    name: []const u8,
    principal: []const u8,
    tenant: []const u8,
    read: bool = false,
    retain: bool = false,
    import: bool = false,
    disclose_all: bool = false,
};

pub const Object = struct { reference: state.Reference, bytes: []const u8 };

pub const Frozen = struct {
    artifacts: []const Object,
    history: []const Object,
    description: []const u8,
};

pub const Policy = struct {
    scopes: []const Scope = &.{},
    context: ?*anyopaque = null,
    disclosure: ?*const fn (?*anyopaque, registry.Authority, Scope, Frozen) anyerror!void = null,

    pub fn validate(self: Policy) !void {
        for (self.scopes, 0..) |scope, index| {
            try validateName(scope.name);
            try validateName(scope.principal);
            try validateName(scope.tenant);
            for (self.scopes[0..index]) |prior|
                if (std.mem.eql(u8, prior.name, scope.name)) return error.InvalidConfiguration;
        }
    }

    pub fn authorize(
        self: Policy,
        authority: registry.Authority,
        scope_name: []const u8,
        action: Action,
    ) !void {
        const scope = try self.authorizedScope(authority, scope_name);
        const permitted = switch (action) {
            .read => scope.read,
            .retain => scope.retain,
            .import => scope.import,
        };
        if (!permitted) return error.Denied;
    }

    pub fn disclose(
        self: Policy,
        authority: registry.Authority,
        scope_name: []const u8,
        frozen: Frozen,
    ) !void {
        try self.authorize(authority, scope_name, .retain);
        const scope = try self.authorizedScope(authority, scope_name);
        if (self.disclosure) |check| return check(self.context, authority, scope, frozen);
        if (!scope.disclose_all) return error.Denied;
    }

    fn authorizedScope(
        self: Policy,
        authority: registry.Authority,
        scope_name: []const u8,
    ) !Scope {
        if (self.scopes.len == 0) return error.ArtifactUnavailable;
        if (authority.revoked or !authority.disclosure) return error.Denied;
        for (self.scopes) |scope| {
            if (std.mem.eql(u8, scope.name, scope_name) and
                std.mem.eql(u8, scope.principal, authority.principal) and
                std.mem.eql(u8, scope.tenant, authority.tenant)) return scope;
        }
        return error.Denied;
    }
};

fn validateName(value: []const u8) !void {
    if (value.len == 0 or value.len > 128 or !std.unicode.utf8ValidateSlice(value))
        return error.InvalidConfiguration;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidConfiguration;
}

test "reuse policy checks current exact authority before scope access" {
    const policy: Policy = .{ .scopes = &.{.{
        .name = "shared",
        .principal = "owner",
        .tenant = "local",
        .read = true,
        .retain = true,
        .import = true,
    }} };
    var authority: registry.Authority = .{
        .grants = &.{},
        .principal = "owner",
        .tenant = "local",
    };
    try policy.validate();
    inline for (.{ Action.read, Action.retain, Action.import }) |action| {
        try policy.authorize(authority, "shared", action);
        try std.testing.expectError(error.Denied, policy.authorize(authority, "unknown", action));
    }
    authority.revoked = true;
    try std.testing.expectError(error.Denied, policy.authorize(authority, "shared", .read));
    authority.revoked = false;
    authority.principal = "another";
    try std.testing.expectError(error.Denied, policy.authorize(authority, "shared", .import));
    authority.principal = "owner";
    authority.tenant = "another";
    try std.testing.expectError(error.Denied, policy.authorize(authority, "shared", .retain));
    authority.tenant = "local";
    authority.disclosure = false;
    try std.testing.expectError(error.Denied, policy.authorize(authority, "shared", .read));
}

test "disclosure receives complete frozen bytes and cannot be bypassed by scope grant" {
    const Check = struct {
        fn check(_: ?*anyopaque, _: registry.Authority, scope: Scope, frozen: Frozen) !void {
            try std.testing.expectEqualStrings("shared", scope.name);
            try std.testing.expectEqualStrings("code", frozen.artifacts[0].bytes);
            try std.testing.expectEqualStrings("history", frozen.history[0].bytes);
            try std.testing.expectEqualStrings("description", frozen.description);
            return error.Denied;
        }
    };
    var policy: Policy = .{ .scopes = &.{.{
        .name = "shared",
        .principal = "owner",
        .tenant = "local",
        .retain = true,
        .disclose_all = true,
    }} };
    const authority: registry.Authority = .{
        .grants = &.{},
        .principal = "owner",
        .tenant = "local",
    };
    const frozen: Frozen = .{
        .artifacts = &.{.{ .reference = .{ .digest = @splat(1), .bytes = 4 }, .bytes = "code" }},
        .history = &.{.{ .reference = .{ .digest = @splat(2), .bytes = 7 }, .bytes = "history" }},
        .description = "description",
    };
    try policy.disclose(authority, "shared", frozen);
    policy.disclosure = Check.check;
    try std.testing.expectError(error.Denied, policy.disclose(authority, "shared", frozen));
    const unconfigured: Policy = .{};
    try std.testing.expectError(
        error.ArtifactUnavailable,
        unconfigured.disclose(authority, "shared", frozen),
    );
}
