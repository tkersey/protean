//! Small native HTTPS probe driven by the independent controlled endpoint.
const std = @import("std");
const native = @import("protean_native");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    if (args.next()) |mode| {
        if (!std.mem.eql(u8, mode, "https")) return error.InvalidArguments;
        const endpoint = args.next() orelse return error.InvalidArguments;
        const root_path = args.next() orelse return error.InvalidArguments;
        const timeout_ms = try std.fmt.parseInt(u32, args.next() orelse return error.InvalidArguments, 10);
        const body = args.next() orelse return error.InvalidArguments;
        if (args.next() != null) return error.InvalidArguments;
        const root = try std.Io.Dir.cwd().readFileAlloc(init.io, root_path, init.gpa, .limited(64 * 1024));
        defer init.gpa.free(root);
        const result = native.https.post(init.gpa, init.io, .{ .endpoint = endpoint, .token = "qualification-only", .trust_root = root, .response_limit = 1024, .timeout_ms = timeout_ms }, body);
        var buffer: [4096]u8 = undefined;
        var out = std.Io.File.stdout().writer(init.io, &buffer);
        switch (result) {
            .captured => |capture| {
                defer capture.deinit(init.gpa);
                try out.interface.print("captured {d} {s}\n", .{ capture.status, capture.request_id orelse "absent" });
                try out.interface.writeAll(capture.body);
            },
            .definitely_not_sent => |err| try out.interface.print("not-sent {s}\n", .{@errorName(err)}),
            .unknown => |err| try out.interface.print("unknown {s}\n", .{@errorName(err)}),
        }
        try out.interface.flush();
        return;
    }
    return error.ExpectedProbeMode;
}
