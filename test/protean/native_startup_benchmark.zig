const std = @import("std");
const horos = @import("horos");
const native = @import("protean_native");
const recovery = @import("adaptive_recovery.zig");
const t = @import("adaptive_types");
const cleanup = @import("native_test_support.zig").cleanup;

const Measurement = struct {
    nanoseconds: i96,
    allocations: usize,
    allocated_bytes: usize,
    retained_bytes: usize,

    fn start(io: std.Io, counter: *const std.testing.FailingAllocator) Measurement {
        return .{
            .nanoseconds = std.Io.Clock.awake.now(io).nanoseconds,
            .allocations = counter.alloc_index,
            .allocated_bytes = counter.allocated_bytes,
            .retained_bytes = counter.allocated_bytes - counter.freed_bytes,
        };
    }

    fn finish(
        self: Measurement,
        io: std.Io,
        counter: *const std.testing.FailingAllocator,
    ) Measurement {
        const end = start(io, counter);
        return .{
            .nanoseconds = end.nanoseconds - self.nanoseconds,
            .allocations = end.allocations - self.allocations,
            .allocated_bytes = end.allocated_bytes - self.allocated_bytes,
            .retained_bytes = end.retained_bytes - self.retained_bytes,
        };
    }
};

test "native startup admission benchmark" {
    const a = std.heap.smp_allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const assets = try startupAssets(arena.allocator());
    var handlers = try recovery.workspaceRecoveryHandlers(a);
    defer handlers.deinit();
    for (0..3) |sample| try measureStartup(a, io, assets, handlers, sample, false);
    try measureStartup(a, io, assets, handlers, 0, true);
}

fn startupAssets(a: std.mem.Allocator) !native.discovery.Assets {
    const image = @embedFile("adaptive_image");
    const metadata = @embedFile("adaptive_application");
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(horos.data.program_image.identity_domain);
    hash.update(image);
    return .{
        .image = image,
        .application = metadata,
        .manifest = try @import("native_test_support.zig").ownerManifest(
            a,
            image,
            hash.finalResult(),
            metadata,
        ),
    };
}

fn measureStartup(
    a: std.mem.Allocator,
    io: std.Io,
    assets: native.discovery.Assets,
    handlers: native.Registry,
    sample: usize,
    metered: bool,
) !void {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const length = try temporary.dir.realPath(io, &path_buffer);
    const path = try std.fmt.allocPrint(a, "{s}/state", .{path_buffer[0..length]});
    defer a.free(path);
    var namespace = try native.Namespace.open(a, io, path);
    defer cleanup("startup namespace close", namespace.close());
    var counter = std.testing.FailingAllocator.init(a, .{});
    const measured = if (metered) counter.allocator() else a;
    const discovery_start = Measurement.start(io, &counter);
    var application = try native.discovery.Application.init(t, measured, assets, handlers);
    defer application.deinit();
    const discovery = discovery_start.finish(io, &counter);
    const profile: native.tasks.Profile = .{
        .id = "startup-benchmark",
        .runtime_identity = @splat(73),
        .bytes = "startup-benchmark",
        .authority = .{ .grants = &.{}, .principal = "startup-benchmark", .tenant = "local" },
    };
    const service_start = Measurement.start(io, &counter);
    var service = try native.tasks.Service(t).init(
        measured,
        io,
        &namespace,
        assets,
        &application,
        handlers,
        profile,
    );
    defer cleanup("startup service close", service.close(measured));
    const service_measurement = service_start.finish(io, &counter);
    printMeasurement("discovery", sample, metered, assets.image.len, discovery);
    printMeasurement("service", sample, metered, assets.image.len, service_measurement);
}

fn printMeasurement(
    phase: []const u8,
    sample: usize,
    metered: bool,
    image_bytes: usize,
    value: Measurement,
) void {
    std.debug.print(
        "startup phase={s} sample={d} metered={any} image_bytes={d} ns={d} allocations={d} " ++
            "allocated_bytes={d} retained_bytes={d}\n",
        .{
            phase,
            sample,
            metered,
            image_bytes,
            value.nanoseconds,
            value.allocations,
            value.allocated_bytes,
            value.retained_bytes,
        },
    );
}
