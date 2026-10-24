//! Verification-only source emission and read-only clone-phase inspection.
//! The full invocation/source-oracle peer remains in workspace_semantics.zig.
const std = @import("std");
const horos = @import("horos");
const native = @import("protean_native");
const kosmos = @import("kosmos");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next() orelse return error.MissingMode;
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (std.mem.eql(u8, mode, "mobility")) {
        var builder = horos.source.Builder.init(a);
        defer builder.deinit();
        const module = try @import("runtime_mobility_source.zig").build(&builder);
        const transport = try native.source_records.encode(a, module);
        try output.interface.writeAll(try std.json.Stringify.valueAlloc(a, .{ .transport = transport }, .{}));
    } else if (std.mem.eql(u8, mode, "specialized-policy")) {
        const compiler_allocator = init.gpa;
        const kind = args.next() orelse return error.MissingKind;
        const source_path = args.next() orelse return error.MissingSource;
        const text = try std.Io.Dir.cwd().readFileAlloc(init.io, source_path, a, .unlimited);
        var diagnostic: native.program_construction.Diagnostic = .{};
        var built = if (std.mem.eql(u8, kind, "component-recipe")) blk: {
            const catalog_path = args.next() orelse return error.MissingCatalog;
            const catalog = try std.Io.Dir.cwd().readFileAlloc(init.io, catalog_path, a, .unlimited);
            break :blk try native.program_construction.buildComponent(compiler_allocator, catalog, text);
        } else if (std.mem.eql(u8, kind, "mobility"))
            try native.program_construction.buildExposed(compiler_allocator, text, &.{
                .{ .effect = 0, .class = .observation },
                .{ .effect = 1, .class = .input },
                .{ .effect = 2, .class = .observation },
            }, null, &diagnostic)
        else
            return error.InvalidKind;
        defer built.deinit();
        var packaged = try kosmos.Prepared.init(compiler_allocator, built.image);
        defer packaged.deinit();
        const guest = try horos.data.program_image.Admitted.decode(compiler_allocator, built.image);
        defer guest.deinit();
        const bytes = try kosmos.RuntimeCompiler.compile(compiler_allocator, .{
            .guest = guest,
            .horos_package = packaged.runtime.content.value.manifest.compiler.horos_package,
            .hooks = .{ .control = false, .storage = false },
        });
        defer compiler_allocator.free(bytes);
        var selected = try kosmos.RuntimeArtifact.init(compiler_allocator, bytes, kosmos.RuntimeCapsule.reference(bytes).digest);
        defer selected.deinit();
        try kosmos.RuntimeCompiler.validate(compiler_allocator, &selected);
        try output.interface.print("{{\"roots\":[\"{s}\"],\"checkers\":[\"{s}\"],\"guard\":false}}", .{
            std.fmt.bytesToHex(kosmos.RuntimeCompiler.approvedRootIdentity(&selected), .lower),
            kosmos.RuntimeCompiler.checker_identity,
        });
    } else if (std.mem.eql(u8, mode, "controller-converter")) {
        const source_path = args.next() orelse return error.MissingSource;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, source_path, a, .unlimited);
        var original = try native.source_records.decode(a, bytes);
        defer original.deinit();
        const module = original.module;
        const entry = module.functions[@intCast(module.entry)];
        const input = module.variables[@intCast(entry.parameters[0])];
        var schema = try @import("horos_data").schema.canonicalize(a, module.schemas, module.schemas[@intCast(input)].product[1]);
        defer schema.deinit();
        const private = schema.descriptor.root;
        const carry = schema.descriptor.types[@intCast(private)].sum[1];
        var builder = horos.source.Builder.init(a);
        defer builder.deinit();
        try builder.schemas.appendSlice(builder.allocator(), schema.descriptor.types);
        const view = try @import("protean_contracts").schema(@import("protean_contracts").controller.OwnerView, &builder);
        const converter_input = try builder.schema(.{ .product = &.{ carry, view } });
        const converter = try builder.declare(&.{converter_input}, private, &.{}, &.{});
        const retained = try builder.primitive(carry, .field, &.{try builder.reference(builder.parameter(converter, 0))}, 0);
        try builder.define(converter, try builder.pure(try builder.primitive(private, .variant, &.{retained}, 1)));
        try output.interface.writeAll(try native.source_records.encode(a, builder.module(converter, try builder.scalar(void))));
    } else if (std.mem.eql(u8, mode, "capsule-artifact")) {
        const capsule_path = args.next() orelse return error.MissingCapsule;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, capsule_path, a, .unlimited);
        var envelope = try kosmos.RuntimeCapsule.read(a, bytes);
        defer envelope.deinit();
        const artifact = envelope.value.record.artifact;
        try output.interface.print("{{\"digest\":\"{s}\",\"bytes\":{d}}}", .{ std.fmt.bytesToHex(artifact.digest, .lower), artifact.bytes });
    } else if (std.mem.eql(u8, mode, "capsule-phase")) {
        const runtime_path = args.next() orelse return error.MissingRuntime;
        const capsule_path = args.next() orelse return error.MissingCapsule;
        try capsulePhase(a, init.io, runtime_path, capsule_path, &output.interface);
    } else return error.InvalidMode;
    try output.interface.flush();
}

/// Inspect immutable published objects without a restore verifier or authority.
pub fn capsulePhase(a: std.mem.Allocator, io: std.Io, runtime_path: []const u8, capsule_path: []const u8, output: *std.Io.Writer) !void {
    const runtime_bytes = try std.Io.Dir.cwd().readFileAlloc(io, runtime_path, a, .unlimited);
    const capsule_bytes = try std.Io.Dir.cwd().readFileAlloc(io, capsule_path, a, .unlimited);
    var selected = try kosmos.RuntimeArtifact.init(a, runtime_bytes, kosmos.RuntimeCapsule.reference(runtime_bytes).digest);
    defer selected.deinit();
    var envelope = try kosmos.RuntimeCapsule.read(a, capsule_bytes);
    defer envelope.deinit();
    if (envelope.value.record.kind != .outer_execution or envelope.value.record.operation == null or
        !std.meta.eql(envelope.value.record.artifact, kosmos.RuntimeCapsule.reference(runtime_bytes))) return error.InvalidPhase;
    var state = try horos.data.state_image.decodeGraph(a, envelope.value.checkpoint);
    defer state.deinit();
    try horos.data.state_admission.validateAdmitted(a, selected.program, state.state);
    var clone_frames: usize = 0;
    var clone_bindings: usize = 0;
    var active_clone_frames: usize = 0;
    for (state.state.nodes) |node| {
        const block = switch (node.record) {
            .control => |control| control.block,
            .continuation => |continuation| continuation.source_block,
            else => continue,
        };
        const function = selected.program.program().blocks[@intCast(block)].function;
        for (selected.content.value.recovery.anchors) |anchor| {
            if ((anchor.role != .clone_rebase and anchor.role != .clone_context) or anchor.function != function) continue;
            active_clone_frames += 1;
            const frame = node.activation orelse return error.MissingActivation;
            // Lowering can retire entry parameters after their last use.
            // The live continuation locals carry the updated cursor/map.
            // Require execution beyond entry and actual retained locals;
            // a matching declaration alone is not a mid-operation witness.
            if (frame.position == 0 or frame.bindings.len == 0) continue;
            clone_frames += 1;
            clone_bindings += frame.bindings.len;
        }
    }
    try output.print("{{\"clone_frames\":{d},\"clone_bindings\":{d},\"active_clone_frames\":{d},\"outer_revision\":\"{d}\"}}", .{ clone_frames, clone_bindings, active_clone_frames, envelope.value.record.outer_revision });
}
