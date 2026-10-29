//! Protean admission over an application-owned Horos source module.
const std = @import("std");
const horos = @import("horos");
const contracts = @import("protean_contracts");
const admission = @import("admission.zig");
pub const catalogs = @import("catalogs.zig");
const source = horos.source;
const a = horos.authoring;
const native = horos.data.schema.native;

/// Optional native authoring observations. These callbacks never enter a Module,
/// BPI3, or PST3, and borrow their context only for the compilation call.
pub const CompileStage = enum {
    descriptors,
    application_source,
    protean_admission,
    horos_compile,
    complete,
};
pub const CompileObserver = struct {
    context: *anyopaque,
    enter: *const fn (*anyopaque, CompileStage) void,
};
pub const CompileOptions = struct {
    observer: ?CompileObserver = null,
    horos_options: horos.program.CompileOptions = .{},

    fn stage(self: CompileOptions, next: CompileStage) void {
        if (self.observer) |observer| observer.enter(observer.context, next);
    }
};

pub const Context = struct {
    builder: *source.Builder,
    registry: *admission.Registry,
    author: *a.Context,
    catalogs: catalogs.Catalogs = .{},

    pub fn init(builder: *source.Builder, registry: *admission.Registry) !Context {
        return .{ .builder = builder, .registry = registry, .author = try a.Context.init(builder) };
    }

    pub fn schema(self: Context, comptime T: type) !*const a.Schema(a.Shape(T)) {
        return self.author.schema(T);
    }

    /// Declare environmental I/O; protected roles still need their checked owner.
    pub fn external(
        self: Context,
        identity: []const u8,
        payload: anytype,
        result: anytype,
        role: admission.Role,
    ) !*const a.Operation(
        a.OperationSignature(
            a.ShapeOf(@TypeOf(payload)),
            a.ShapeOf(@TypeOf(result)),
            native.Fields(&.{}, &.{}),
        ),
    ) {
        const operation = try self.author.external(identity, payload, result);
        try self.registry.classify(try a.interop.operationId(self.author, operation), role);
        return operation;
    }

    pub fn literal(self: Context, comptime T: type, value: T) !*const a.Value(a.Shape(T)) {
        const encoded = try contracts.encodeOwned(T, self.builder.arena.child_allocator, value);
        defer self.builder.arena.child_allocator.free(encoded);
        return a.interop.encodedLiteral(self.author, try self.schema(T), encoded);
    }
};

/// The native emitter runs once while authoring. All resulting control is source data.
pub fn system(comptime spec: anytype) type {
    comptime {
        if (catalogs.sourceIssue(
            spec,
        )) |issue| @compileError(
            "protean.system: " ++ @tagName(issue),
        );
        for (.{ "InitialArgs", "Result", "Failure", "application" }) |name| {
            if (!@hasField(@TypeOf(spec), name))
                @compileError("protean.system requires " ++ name);
        }
        if (!@hasDecl(spec.application, "emit"))
            @compileError("protean.system application must declare emit(context)");
    }
    return struct {
        pub const Source = spec;
        pub const InitialArgs = spec.InitialArgs;
        pub const Result = spec.Result;
        pub const Failure = spec.Failure;
        pub const Application = spec.application;
    };
}

/// Returned output owns its storage and remains valid after the builder is released.
pub fn compile(allocator: std.mem.Allocator, comptime System: type) !source.Compiled {
    return compileObserved(allocator, System, .{});
}

pub fn compileObserved(
    allocator: std.mem.Allocator,
    comptime System: type,
    options: CompileOptions,
) !source.Compiled {
    options.horos_options.resetObservations();
    options.stage(.descriptors);
    var builder = source.Builder.init(allocator);
    defer builder.deinit();
    var registry = admission.Registry.init(builder.allocator());
    defer registry.deinit();
    var context = try Context.init(&builder, &registry);
    const initial = try a.interop.schemaId(context.author, try context.schema(System.InitialArgs));
    const result = try a.interop.schemaId(context.author, try context.schema(System.Result));
    const failure = try a.interop.schemaId(context.author, try context.schema(System.Failure));
    context.catalogs = try catalogs.install(context, System.Source);
    options.stage(.application_source);
    const module = try System.Application.emit(context);
    options.stage(.protean_admission);
    if (module.entry >= module.functions.len) return error.InvalidEntry;
    const entry = module.functions[@intCast(module.entry)];
    if (entry.parameters.len != 1 or
        entry.parameters[0] >= module.variables.len or
        module.variables[@intCast(entry.parameters[0])] != initial or
        entry.result != result or module.failure != failure)
        return error.TypeMismatch;
    try admission.verify(allocator, module, &registry);
    options.stage(.horos_compile);
    const compiled = if (registry.compiled_imports.items.len == 0)
        try source.lowerObserved(allocator, module, options.horos_options)
    else
        try @import("compiled_tool.zig").link(allocator, module, &registry, options.horos_options);
    options.stage(.complete);
    return compiled;
}
