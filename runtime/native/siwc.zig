const std = @import("std");
const protocol = @import("siwc_protocol.zig");
const process = @import("siwc_process.zig");
const Allocator = std.mem.Allocator;
pub const Cancellation = process.Cancellation;
pub const Clock = process.Clock;
pub const Lease = protocol.Lease;
pub const Status = protocol.Status;
pub const Phase = protocol.Phase;
pub const Catalog = protocol.Catalog;
pub const Model = protocol.Model;
pub const binding = protocol.binding;
pub const validLabel = protocol.validLabel;
pub const local_timeout_ms = process.local_timeout_ms;
pub const credential_timeout_ms = process.credential_timeout_ms;
pub const models_timeout_ms = process.models_timeout_ms;

pub const Options = struct {
    account: []const u8,
    executable: ?[]const u8 = null,
    auth_dir: ?[]const u8 = null,
    home: ?[]const u8 = null,
    path: ?[]const u8 = null,
    clock: Clock = .{},
};

const Coordination = struct {
    next: ?*Coordination,
    root: []const u8,
    account: []const u8,
    references: usize = 1,
    busy: std.atomic.Value(bool) = .init(false),
};
var coordinators: ?*Coordination = null;
var coordinator_mutex: std.Io.Mutex = .init;

fn coordinate(io: std.Io, root: []const u8, account: []const u8) !*Coordination {
    try coordinator_mutex.lock(io);
    defer coordinator_mutex.unlock(io);
    var cursor = coordinators;
    while (cursor) |item| : (cursor = item.next) {
        if (std.mem.eql(u8, root, item.root) and std.mem.eql(u8, account, item.account)) {
            item.references += 1;
            return item;
        }
    }
    const a = std.heap.page_allocator;
    const item = try a.create(Coordination);
    errdefer a.destroy(item);
    const owned_root = try a.dupe(u8, root);
    errdefer a.free(owned_root);
    item.* = .{
        .root = owned_root,
        .account = try a.dupe(u8, account),
        .next = coordinators,
    };
    coordinators = item;
    return item;
}

fn release(io: std.Io, item: *Coordination) void {
    coordinator_mutex.lockUncancelable(io);
    defer coordinator_mutex.unlock(io);
    item.references -= 1;
    if (item.references != 0) return;
    std.debug.assert(!item.busy.load(.acquire));
    var slot = &coordinators;
    while (slot.*) |cursor| : (slot = &cursor.next) {
        if (cursor != item) continue;
        slot.* = item.next;
        const a = std.heap.page_allocator;
        a.free(item.root);
        a.free(item.account);
        a.destroy(item);
        return;
    }
    unreachable;
}

fn absolute(path: []const u8) bool {
    return std.fs.path.isAbsolute(path) and std.mem.indexOfScalar(u8, path, 0) == null;
}
fn copyOptional(a: Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |bytes| try a.dupe(u8, bytes) else null;
}
fn freeOptional(a: Allocator, value: ?[]const u8) void {
    if (value) |bytes| a.free(bytes);
}

fn effectiveRoot(a: Allocator, io: std.Io, options: Options) ![]const u8 {
    const path = if (options.auth_dir) |root|
        try a.dupe(u8, root)
    else
        try std.fs.path.join(
            a,
            &.{ options.home orelse return error.InvalidSiwcSelection, ".config", "siwc" },
        );
    defer a.free(path);
    var end = path.len;
    while (end > 0) {
        const resolved = std.Io.Dir.realPathFileAbsoluteAlloc(io, path[0..end], a) catch |err|
            switch (err) {
                error.FileNotFound, error.NotDir => {
                    const parent = std.fs.path.dirname(path[0..end]) orelse return err;
                    end = parent.len;
                    continue;
                },
                else => return err,
            };
        defer a.free(resolved);
        return std.fs.path.resolve(a, &.{ resolved, std.mem.trimStart(u8, path[end..], "/") });
    }
    return error.InvalidSiwcSelection;
}

pub const Selection = struct {
    allocator: Allocator,
    io: std.Io,
    options: Options,
    resolved: ?[:0]const u8 = null,
    version_checked: bool = false,
    initialization: std.atomic.Value(bool) = .init(false),
    coordinator: ?*Coordination = null,

    pub fn init(a: Allocator, io: std.Io, options: Options) !*Selection {
        if (!validLabel(options.account)) return error.InvalidSiwcSelection;
        for ([_]?[]const u8{ options.executable, options.auth_dir, options.home }) |value|
            if (value) |path| if (!absolute(path)) return error.InvalidSiwcSelection;
        if (options.auth_dir == null and options.home == null) return error.InvalidSiwcSelection;
        const self = try a.create(Selection);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .io = io, .options = .{
            .account = try a.dupe(u8, options.account),
            .clock = options.clock,
        } };
        errdefer self.freeOptions();
        self.options.executable = try copyOptional(a, options.executable);
        self.options.auth_dir = try copyOptional(a, options.auth_dir);
        self.options.home = try copyOptional(a, options.home);
        self.options.path = try copyOptional(a, options.path);
        return self;
    }
    fn freeOptions(self: *Selection) void {
        const a = self.allocator;
        a.free(self.options.account);
        freeOptional(a, self.options.executable);
        freeOptional(a, self.options.auth_dir);
        freeOptional(a, self.options.home);
        freeOptional(a, self.options.path);
    }
    pub fn deinit(self: *Selection) void {
        if (self.coordinator) |item| release(self.io, item);
        if (self.resolved) |path| self.allocator.free(path);
        self.freeOptions();
        const a = self.allocator;
        self.* = undefined;
        a.destroy(self);
    }
    pub fn nowSeconds(self: *const Selection) i64 {
        return self.options.clock.seconds(self.io);
    }
    fn resolve(self: *Selection) ![:0]const u8 {
        if (self.options.executable) |path| return executable(self.allocator, self.io, path);
        var paths = std.mem.splitScalar(u8, self.options.path orelse "", ':');
        while (paths.next()) |directory| {
            if (!absolute(directory)) continue;
            const path = try std.fs.path.join(self.allocator, &.{ directory, "siwc" });
            defer self.allocator.free(path);
            const result = executable(self.allocator, self.io, path) catch |err| switch (err) {
                error.Canceled, error.OutOfMemory => return err,
                else => continue,
            };
            return result;
        }
        return error.SiwcExecutableUnavailable;
    }
    fn ready(self: *Selection, cancelled: Cancellation) !void {
        try process.lock(self.io, &self.initialization, cancelled);
        defer self.initialization.store(false, .release);
        if (self.resolved == null) self.resolved = try self.resolve();
        if (!self.version_checked) {
            var output = try self.invoke(.version, cancelled);
            defer output.deinit();
            try protocol.version(output.slice());
            self.version_checked = true;
        }
        if (self.coordinator == null) {
            const root = try effectiveRoot(self.allocator, self.io, self.options);
            defer self.allocator.free(root);
            self.coordinator = try coordinate(self.io, root, self.options.account);
        }
    }
    pub fn status(self: *Selection, cancelled: Cancellation) !Status {
        try self.ready(cancelled);
        var output = try self.invoke(.status, cancelled);
        defer output.deinit();
        return protocol.status(std.heap.page_allocator, output.slice(), self.options.account);
    }
    pub fn models(self: *Selection, a: Allocator, cancelled: Cancellation) !Catalog {
        try self.ready(cancelled);
        const gate = &self.coordinator.?.busy;
        try process.lock(self.io, gate, cancelled);
        defer gate.store(false, .release);
        var output = self.invoke(.models, cancelled) catch |err|
            return self.failureReason(err, cancelled);
        defer output.deinit();
        return protocol.models(a, output.slice());
    }
    pub fn credential(
        self: *Selection,
        a: Allocator,
        expected: [32]u8,
        cancelled: Cancellation,
    ) !Lease {
        try self.ready(cancelled);
        const gate = &self.coordinator.?.busy;
        try process.lock(self.io, gate, cancelled);
        defer gate.store(false, .release);
        var output = self.invoke(.credential, cancelled) catch |err|
            return self.failureReason(err, cancelled);
        defer output.deinit();
        try process.check(self.io, cancelled);
        return protocol.credential(
            a,
            output.slice(),
            self.options.account,
            expected,
            self.nowSeconds(),
        );
    }
    fn failureReason(self: *Selection, original: anyerror, cancelled: Cancellation) anyerror {
        if (original != error.SiwcCommandFailed) return original;
        const observed = self.status(cancelled) catch |err|
            return if (err == error.Canceled) err else original;
        return switch (observed.phase) {
            .signed_out, .pending, .reauthentication_required => error.ChatGPTSignInRequired,
            .plan_usage_disabled => error.ChatGPTPlanUsageDisabled,
            .ready, .refresh_required => original,
        };
    }
    fn invoke(self: *Selection, command: Command, cancelled: Cancellation) !process.Output {
        var argv: [10][]const u8 = undefined;
        argv[0] = self.resolved.?;
        var count: usize = 2;
        if (command == .version) {
            argv[1] = "--version";
        } else {
            @memcpy(argv[1..7], &[_][]const u8{
                @tagName(command), "--app", "protean", "--account", self.options.account, "--json",
            });
            count = 7;
            if (self.options.auth_dir) |root| {
                argv[7] = "--auth-dir";
                argv[8] = root;
                count = 9;
            }
        }
        return process.run(std.heap.page_allocator, self.io, .{
            .argv = argv[0..count],
            .home = if (self.options.auth_dir == null) self.options.home else null,
            .stdout_bytes_max = command.limit(),
            .timeout_ms = command.timeout(),
            .clock = self.options.clock,
        }, cancelled);
    }
};

const Command = enum {
    version,
    status,
    models,
    credential,

    fn limit(self: Command) usize {
        return switch (self) {
            .version => process.version_bytes_max,
            .models => protocol.models_bytes_max,
            else => protocol.stdout_bytes_max,
        };
    }
    fn timeout(self: Command) i64 {
        return switch (self) {
            .credential => credential_timeout_ms,
            .models => models_timeout_ms,
            else => local_timeout_ms,
        };
    }
};

fn executable(a: Allocator, io: std.Io, path: []const u8) ![:0]const u8 {
    const resolved = std.Io.Dir.realPathFileAbsoluteAlloc(io, path, a) catch |err|
        return switch (err) {
            error.Canceled, error.OutOfMemory => err,
            else => error.SiwcExecutableUnavailable,
        };
    errdefer a.free(resolved);
    const stat = std.Io.Dir.cwd().statFile(io, resolved, .{}) catch |err| return switch (err) {
        error.Canceled => error.Canceled,
        else => error.SiwcExecutableUnavailable,
    };
    if (stat.kind != .file or std.c.access(resolved.ptr, std.c.X_OK) != 0)
        return error.SiwcExecutableUnavailable;
    return resolved;
}

test "selection copies settings without touching helper or store" {
    const a = std.testing.allocator;
    const selection = try Selection.init(a, std.testing.io, .{
        .account = "personal",
        .auth_dir = "/nonexistent/protean-siwc-test",
        .executable = "/nonexistent/protean-siwc-test-executable",
    });
    defer selection.deinit();
    try std.testing.expect(selection.resolved == null);
    try std.testing.expect(selection.coordinator == null);
    try std.testing.expectError(
        error.InvalidSiwcSelection,
        Selection.init(a, std.testing.io, .{ .account = "../bad", .home = "/tmp" }),
    );
    try std.testing.expectError(error.SiwcExecutableUnavailable, selection.status(null));
}

test "coordination shares effective account ownership across selections" {
    const io = std.testing.io;
    const first = try coordinate(io, "/synthetic/siwc", "personal");
    defer release(io, first);
    const second = try coordinate(io, "/synthetic/siwc", "personal");
    defer release(io, second);
    try std.testing.expect(first == second);
    const other = try coordinate(io, "/synthetic/siwc", "work");
    defer release(io, other);
    try std.testing.expect(first != other);
    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Canceled, process.lock(io, &first.busy, &cancelled));
    try std.testing.expect(!first.busy.load(.acquire));
}

test {
    _ = protocol;
    _ = process;
}

const fake_helper =
    \\#!/bin/sh
    \\base=${0%/*}
    \\printf '%s\n' "$1" >> "$base/commands"
    \\if [ "$1" = --version ]; then
    \\  [ "$#" = 1 ] || exit 2
    \\  printf '0.1.3\n'
    \\  exit 0
    \\fi
    \\[ "$#" = 8 ] || exit 2
    \\[ "$2" = --app ] && [ "$3" = protean ] || exit 2
    \\[ "$4" = --account ] && [ "$5" = personal ] || exit 2
    \\[ "$6" = --json ] && [ "$7" = --auth-dir ] || exit 2
    \\[ "$8" = '/synthetic auth root' ] || exit 2
    \\[ -z "${HOME+x}" ] && [ -z "${OPENAI_API_KEY+x}" ] || exit 2
    \\case "$1" in
    \\ status)
    \\  phase=refresh_required
    \\  if [ -f "$base/failure-phase" ]; then IFS= read -r phase < "$base/failure-phase"; fi
    \\  printf '{"app":"protean","account":"personal","client_id":"client","subject":"subject","email":null,"phase":"%s","expires_at":null}\n' "$phase" ;;
    \\ models)
    \\  [ ! -f "$base/failure-phase" ] || exit 1
    \\  printf '%s\n' '[{"slug":"approved","display_name":"Approved model"}]' ;;
    \\ credential)
    \\  [ ! -f "$base/failure-phase" ] || exit 1
    \\  if [ -f "$base/lease" ]; then token=synthetic-second; else
    \\    token=synthetic-first
    \\    : > "$base/lease"
    \\  fi
    \\  printf '{"version":1,"provider":"chatgpt","app":"protean","account":"personal","issuer":"https://auth.openai.com","client_id":"client","subject":"subject","access_token":"%s","token_type":"Bearer","resource":"https://api.openai.com/v1","scope":"resource.invoke chatgpt.tokens.use.direct","expires_at":9999999999}\n' "$token" ;;
    \\ *) exit 2 ;;
    \\esac
;

test "fake helper witnesses fixed argv cached version metadata and independent renewal leases" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{
        .sub_path = "siwc",
        .data = fake_helper,
        .flags = .{ .permissions = .fromMode(0o700) },
    });
    const path = try temporary.dir.realPathFileAlloc(io, "siwc", a);
    defer a.free(path);
    const selection = try Selection.init(a, io, .{
        .account = "personal",
        .executable = path,
        .auth_dir = "/synthetic auth root",
    });
    defer selection.deinit();
    const status = try selection.status(null);
    try std.testing.expectEqual(Phase.refresh_required, status.phase);
    var catalog = try selection.models(a, null);
    defer catalog.deinit();
    try std.testing.expect(catalog.contains("approved"));
    var first = try selection.credential(a, status.binding.?, null);
    defer first.deinit();
    var second = try selection.credential(a, status.binding.?, null);
    defer second.deinit();
    try std.testing.expectEqualStrings("synthetic-first", first.token);
    try std.testing.expectEqualStrings("synthetic-second", second.token);
    const commands = try temporary.dir.readFileAlloc(io, "commands", a, .limited(1024));
    defer a.free(commands);
    try std.testing.expectEqualStrings(
        "--version\nstatus\nmodels\ncredential\ncredential\n",
        commands,
    );
}

test "queued cancellation leaves shared gate owned until its holder releases" {
    const io = std.testing.io;
    var gate = std.atomic.Value(bool).init(true);
    var cancelled = std.atomic.Value(bool).init(false);
    const Waiter = struct {
        fn run(g: *std.atomic.Value(bool), flag: *const std.atomic.Value(bool)) !void {
            return process.lock(std.testing.io, g, flag);
        }
    };
    var waiter = try io.concurrent(Waiter.run, .{ &gate, &cancelled });
    try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    cancelled.store(true, .release);
    try std.testing.expectError(error.Canceled, waiter.await(io));
    try std.testing.expect(gate.load(.acquire));
    gate.store(false, .release);
    try process.lock(io, &gate, null);
    try std.testing.expect(gate.load(.acquire));
    gate.store(false, .release);
}

test "executable resolution excludes relative PATH entries and pins resolved package symlinks" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{
        .sub_path = "real-helper",
        .data = "#!/bin/sh\nprintf '0.1.3\\n'\n",
        .flags = .{ .permissions = .fromMode(0o700) },
    });
    try temporary.dir.symLink(io, "real-helper", "siwc", .{});
    const target = try temporary.dir.realPathFileAlloc(io, "real-helper", a);
    defer a.free(target);
    const directory = std.fs.path.dirname(target).?;
    const paths = try std.fmt.allocPrint(a, ":.:relative:{s}", .{directory});
    defer a.free(paths);
    const selection = try Selection.init(a, io, .{
        .account = "personal",
        .path = paths,
        .auth_dir = "/nonexistent/siwc",
    });
    defer selection.deinit();
    try selection.ready(null);
    try std.testing.expectEqualStrings(target, selection.resolved.?);
    try std.testing.expectError(error.SiwcExecutableUnavailable, executable(a, io, directory));
    const relative = try Selection.init(a, io, .{
        .account = "personal",
        .path = ":.:relative",
        .auth_dir = "/nonexistent/siwc",
    });
    defer relative.deinit();
    try std.testing.expectError(error.SiwcExecutableUnavailable, relative.ready(null));
}

test "failed helper commands use only validated repair phases and preserve renewal failure" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{
        .sub_path = "siwc",
        .data = fake_helper,
        .flags = .{ .permissions = .fromMode(0o700) },
    });
    const path = try temporary.dir.realPathFileAlloc(io, "siwc", a);
    defer a.free(path);
    const selection = try Selection.init(a, io, .{
        .account = "personal",
        .executable = path,
        .auth_dir = "/synthetic auth root",
    });
    defer selection.deinit();
    const Case = struct { phase: []const u8, expected: anyerror };
    const cases = [_]Case{
        .{ .phase = "signed_out", .expected = error.ChatGPTSignInRequired },
        .{ .phase = "pending", .expected = error.ChatGPTSignInRequired },
        .{ .phase = "reauthentication_required", .expected = error.ChatGPTSignInRequired },
        .{ .phase = "plan_usage_disabled", .expected = error.ChatGPTPlanUsageDisabled },
        .{ .phase = "ready", .expected = error.SiwcCommandFailed },
        .{ .phase = "refresh_required", .expected = error.SiwcCommandFailed },
        .{ .phase = "invalid-phase", .expected = error.SiwcCommandFailed },
    };
    for (cases) |case| {
        try temporary.dir.writeFile(io, .{ .sub_path = "failure-phase", .data = case.phase });
        try std.testing.expectError(case.expected, selection.models(a, null));
        try std.testing.expectError(case.expected, selection.credential(
            a,
            binding("client", "subject"),
            null,
        ));
    }
    const commands = try temporary.dir.readFileAlloc(io, "commands", a, .limited(1024));
    defer a.free(commands);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, commands, "--version\n"));
    try std.testing.expectEqual(cases.len * 2, std.mem.count(u8, commands, "status\n"));
    try temporary.dir.deleteFile(io, "failure-phase");
    var lease = try selection.credential(a, binding("client", "subject"), null);
    defer lease.deinit();
    try std.testing.expectEqualStrings("synthetic-first", lease.token);
}
