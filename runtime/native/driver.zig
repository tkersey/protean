//! Stable-address evaluator storage, reachable only by the native task owner.
//! Environmental callbacks receive values/authority, never this handle.
const std = @import("std");
const kosmos = @import("kosmos");
const data = @import("horos_data");
const Content = @import("store.zig").Content;
const Sha256 = @import("hash_abi.zig").Sha256;

pub fn recordDigest(comptime T: type, value: T) [32]u8 {
    var digest: Sha256 = .init(.{});
    Record(T).hash(&digest, value);
    return digest.finalResult();
}

fn Record(comptime T: type) type {
    return struct {
        fn hash(digest: *Sha256, value: T) void {
            switch (@typeInfo(T)) {
                .void => {},
                .bool => digest.update(&.{@intFromBool(value)}),
                .int => |info| {
                    if (info.signedness != .unsigned or info.bits > 64)
                        @compileError("not a natural record field: " ++ @typeName(T));
                    natural(digest, value);
                },
                .@"enum" => |info| Record(info.tag_type).hash(digest, @backingInt(value)),
                .pointer => |info| {
                    if (info.size != .slice or info.child != u8)
                        @compileError("not a byte record field: " ++ @typeName(T));
                    natural(digest, value.len);
                    digest.update(value);
                },
                .array => |info| {
                    if (info.child != u8)
                        @compileError("not a byte record field: " ++ @typeName(T));
                    digest.update(&value);
                },
                .@"struct" => |info| inline for (info.field_names, info.field_types) |field, Field|
                    Record(Field).hash(digest, @field(value, field)),
                .@"union" => {
                    const tag = std.meta.activeTag(value);
                    Record(@TypeOf(tag)).hash(digest, tag);
                    switch (value) {
                        inline else => |payload| Record(@TypeOf(payload)).hash(digest, payload),
                    }
                },
                else => @compileError("not a digested record: " ++ @typeName(T)),
            }
        }
    };
}

fn natural(digest: *Sha256, value: u64) void {
    var encoded: [10]u8 = undefined;
    const length = data.wire.naturalLength(value);
    var remaining = value;
    for (encoded[0..length], 1..) |*byte, position| {
        const continued: u8 = if (position < length) 0x80 else 0;
        byte.* = @as(u8, @as(u7, @truncate(remaining))) | continued;
        remaining >>= 7;
    }
    digest.update(encoded[0..length]);
}

fn capsuleReference(content: Content) kosmos.RuntimeCapsule.Reference {
    return .{ .digest = content.reference.digest, .bytes = content.reference.bytes };
}

const SegmentOrigin = struct {
    input: kosmos.RuntimeCapsule.Reference,
    image: kosmos.RuntimeCapsule.Reference,
    runtime: [32]u8,
    initial: bool,
};

const Storage = struct {
    parent: std.mem.Allocator,
    program: *Program,
    own_program: bool,
    resident: kosmos.Resident,
    live: bool,
    checkpoint: ?*kosmos.Checkpoint,
    capsule: ?*kosmos.CapsuleReceipt,
    capsule_provenance: ?kosmos.RuntimeCapsule.Provenance,
    segment_origin: ?SegmentOrigin,
};

const ProgramStorage = struct {
    parent: std.mem.Allocator,
    prepared: kosmos.Prepared,
    image: kosmos.RuntimeCapsule.Reference,
    residents: usize = 0,
};

/// Shared prepared image, owned by the single task service. Its address remains
/// stable until all residents have retired; no adapter receives this handle.
pub const Program = opaque {
    fn storage(self: *Program) *ProgramStorage {
        return @ptrCast(@alignCast(self));
    }
    pub fn open(a: std.mem.Allocator, image: Content) !*Program {
        return openSelected(a, image, null);
    }
    /// Runtime selection is made by the task owner after artifact approval.
    pub fn openSelected(
        a: std.mem.Allocator,
        image: Content,
        runtime: ?*const kosmos.RuntimeArtifact,
    ) !*Program {
        const owner = try a.create(ProgramStorage);
        errdefer a.destroy(owner);
        owner.* = .{
            .parent = a,
            .prepared = undefined,
            .image = capsuleReference(image),
        };
        owner.prepared = if (runtime) |selected| try kosmos.Prepared.initWithRuntime(
            a,
            image.bytes,
            selected,
        ) else try kosmos.Prepared.init(a, image.bytes);
        return @ptrCast(owner);
    }
    pub fn close(self: *Program) !void {
        const owner = self.storage();
        if (owner.residents != 0) return error.UnfinishedSession;
        self.destroyUnreferenced();
    }
    fn destroyUnreferenced(self: *Program) void {
        const owner = self.storage();
        std.debug.assert(owner.residents == 0);
        owner.prepared.deinit();
        owner.parent.destroy(owner);
    }
    /// Independent guest admission under this owner's already admitted runtime.
    /// The returned preparation holds its own strong lease; no guest state or
    /// environmental authority is shared.
    pub fn prepare(self: *Program, a: std.mem.Allocator, image: []const u8) !kosmos.Prepared {
        return kosmos.Prepared.initWithRuntime(a, image, &self.storage().prepared.runtime);
    }
    pub fn retainRuntime(self: *Program) !kosmos.RuntimeArtifact {
        return self.storage().prepared.runtime.clone();
    }
};

pub const Driver = opaque {
    fn storage(self: *Driver) *Storage {
        return @ptrCast(@alignCast(self));
    }

    pub fn open(
        a: std.mem.Allocator,
        image: Content,
        instance: data.invocation.Instance,
    ) !*Driver {
        return openSelected(a, image, instance, null);
    }
    pub fn openSelected(
        a: std.mem.Allocator,
        image: Content,
        instance: data.invocation.Instance,
        runtime: ?*const kosmos.RuntimeArtifact,
    ) !*Driver {
        const program = try Program.openSelected(a, image, runtime);
        errdefer program.destroyUnreferenced();
        const driver = try start(a, program, instance);
        driver.storage().own_program = true;
        return driver;
    }

    /// The owning task supplies the authenticated capsule verifier. Content
    /// admission alone never installs a resident in the active owner.
    pub fn openCapsule(
        a: std.mem.Allocator,
        image: Content,
        runtime: ?*const kosmos.RuntimeArtifact,
        bytes: []const u8,
        verifier: kosmos.RuntimeCapsule.Verifier,
    ) !*Driver {
        var envelope = try kosmos.RuntimeCapsule.read(a, bytes);
        defer envelope.deinit();
        const program = try Program.openSelected(a, image, runtime);
        errdefer program.destroyUnreferenced();
        const owner = try a.create(Storage);
        errdefer a.destroy(owner);
        owner.* = .{
            .parent = a,
            .program = program,
            .own_program = true,
            .resident = try kosmos.Resident.restoreCapsule(
                a,
                &program.storage().prepared,
                bytes,
                verifier,
            ),
            .live = true,
            .checkpoint = null,
            .capsule = null,
            .capsule_provenance = envelope.value.record.provenance,
            .segment_origin = null,
        };
        program.storage().residents += 1;
        return @ptrCast(owner);
    }

    pub fn runtimeBinding(self: *Driver) !kosmos.RuntimeCapsule.Binding {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        return owner.resident.runtimeBinding();
    }
    pub fn runtimeBytes(self: *Driver, a: std.mem.Allocator) ![]u8 {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        return owner.resident.runtimeBytes(a);
    }
    pub fn runtimeObservation(self: *Driver, a: std.mem.Allocator) !kosmos.RuntimeObservation {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        return owner.resident.runtimeObservation(a);
    }
    pub fn publishCapsule(
        self: *Driver,
        a: std.mem.Allocator,
        kind: kosmos.RuntimeCapsule.Kind,
        provenance: kosmos.RuntimeCapsule.Provenance,
    ) !*kosmos.CapsuleReceipt {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        return owner.resident.publishCapsule(a, kind, provenance);
    }
    pub fn realize(
        self: *Driver,
        expected: kosmos.RuntimeCapsule.Binding,
        selected: *const kosmos.RuntimeArtifact,
        provenance: kosmos.RuntimeCapsule.Provenance,
        publisher: kosmos.RuntimeCapsule.SwitchOwner,
    ) !kosmos.RuntimeCapsule.SwitchDecision {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        owner.segment_origin = null;
        const decision = try owner.resident.realize(expected, selected, provenance, publisher);
        if (decision == .committed) self.clearReceipt();
        return decision;
    }
    pub fn resolveRealization(
        self: *Driver,
        publisher: kosmos.RuntimeCapsule.SwitchOwner,
    ) !kosmos.RuntimeCapsule.SwitchDecision {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        owner.segment_origin = null;
        const decision = try owner.resident.resolveRealization(publisher);
        if (decision == .committed) self.clearReceipt();
        return decision;
    }
    fn clearReceipt(self: *Driver) void {
        const owner = self.storage();
        if (owner.checkpoint) |previous| previous.deinit();
        owner.checkpoint = null;
        if (owner.capsule) |previous| previous.deinit();
        owner.capsule = null;
        owner.capsule_provenance = null;
    }

    pub fn beginAdvance(self: *Driver, control: data.invocation.Control, guest_quantum: u64) !void {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        owner.segment_origin = null;
        try owner.resident.beginAdvance(control, guest_quantum);
        self.clearReceipt();
    }

    pub fn pump(self: *Driver, base_quantum: u64) !kosmos.Session.Pump {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        owner.segment_origin = null;
        const result = try owner.resident.pump(base_quantum);
        self.clearReceipt();
        return result;
    }

    /// Retain an owner receipt through durable publication and later eviction.
    /// Its bytes remain valid until the next successful mutation or retirement.
    pub fn retainCapsule(self: *Driver, provenance: kosmos.RuntimeCapsule.Provenance) ![]const u8 {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        const receipt = try owner.resident.publishCapsule(
            owner.parent,
            .outer_execution,
            provenance,
        );
        if (owner.capsule) |previous| previous.deinit();
        owner.capsule = receipt;
        owner.capsule_provenance = provenance;
        return receipt.bytes();
    }

    pub fn start(
        a: std.mem.Allocator,
        program: *Program,
        instance: data.invocation.Instance,
    ) !*Driver {
        const owner = try a.create(Storage);
        errdefer a.destroy(owner);
        owner.parent = a;
        owner.program = program;
        owner.own_program = false;
        const prepared = &program.storage().prepared;
        owner.resident = switch (instance) {
            .initial_args => |args| try kosmos.Resident.start(a, prepared, args),
            .state => |state| try kosmos.Resident.restore(a, prepared, state),
        };
        program.storage().residents += 1;
        owner.live = true;
        owner.checkpoint = null;
        owner.capsule = null;
        owner.capsule_provenance = null;
        owner.segment_origin = .{
            .input = capsuleReference(.of(switch (instance) {
                .initial_args => |args| args,
                .state => |state| state,
            })),
            .image = program.storage().image,
            .runtime = prepared.runtime.identity,
            .initial = instance == .initial_args,
        };
        return @ptrCast(owner);
    }

    pub const Segment = struct {
        input: kosmos.RuntimeCapsule.Reference,
        image: kosmos.RuntimeCapsule.Reference,
        runtime: [32]u8,
        initial: bool,
        control: [32]u8,
        quantum: u64,
    };

    /// The outcome belongs to output. The checkpoint remains owned here until
    /// the next successful drive or retirement, including after storage fails.
    pub const Publication = struct {
        outcome: []u8,
        checkpoint: []const u8,
        trace: ?kosmos.RuntimeInstrumentation.Output = null,
        guest_work: u64 = 0,
        segment: ?Segment = null,
    };

    pub fn drive(
        self: *Driver,
        output: std.mem.Allocator,
        control: data.invocation.Control,
        quantum: u64,
    ) !Publication {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        const segment: ?Segment = if (owner.segment_origin) |origin| .{
            .input = origin.input,
            .image = origin.image,
            .runtime = origin.runtime,
            .initial = origin.initial,
            .control = recordDigest(data.invocation.Control, control),
            .quantum = quantum,
        } else null;
        var published = try owner.resident.publish(
            .{ .encoded = output },
            control,
            .{ .quantum = quantum, .checkpoint = .receipt },
        );
        const checkpoint = published.takeCheckpoint().?;
        self.clearReceipt();
        owner.checkpoint = checkpoint;
        if (owner.segment_origin) |*origin| {
            origin.input = capsuleReference(.of(checkpoint.bytes()));
            origin.initial = false;
        }
        return .{
            .outcome = published.outcome.encoded,
            .checkpoint = checkpoint.bytes(),
            .trace = published.trace,
            .guest_work = published.guest_work,
            .segment = segment,
        };
    }
    pub fn close(self: *Driver) !void {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        try owner.resident.close();
        self.clearReceipt();
        owner.live = false;
        owner.program.storage().residents -= 1;
        if (owner.own_program) try owner.program.close();
    }
    /// The task owner may call this only after publishing a checkpoint, or for
    /// an explicitly nondurable demo. A failure leaves the resident owned/live.
    pub fn retire(self: *Driver) !void {
        const owner = self.storage();
        if (!owner.live) return error.InvalidState;
        // A freshly restored outer operation has a durable source capsule but
        // no local receipt yet. Allocation failure leaves it live and retryable.
        if (owner.capsule == null and owner.capsule_provenance != null) _ = try self.retainCapsule(
            owner.capsule_provenance.?,
        );
        if (owner.capsule) |capsule| {
            try owner.resident.transferCapsule(capsule, .outer_execution);
            self.clearReceipt();
        } else if (owner.checkpoint) |checkpoint| {
            try owner.resident.transferCheckpoint(checkpoint);
            checkpoint.deinit();
            owner.checkpoint = null;
        } else {
            // A newly restored resident may be retired before its first drive.
            const state = try owner.resident.takeCheckpoint(owner.parent);
            owner.parent.free(state);
        }
        owner.live = false;
        owner.program.storage().residents -= 1;
        if (owner.own_program) try owner.program.close();
    }
    /// Retired handles remain allocated until the enclosing owner drops them,
    /// allowing all ordinary operations after close to reject before access.
    pub fn destroy(self: *Driver) !void {
        const owner = self.storage();
        if (owner.live) return error.UnfinishedSession;
        owner.parent.destroy(owner);
    }
};

test "record digests match the Horos record encoding hashed by std, including declared tag values" {
    const Oracle = struct {
        fn expect(comptime T: type, value: T) !void {
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            var writer: data.wire.Writer = .{ .hasher = &hash };
            try data.record.writeAlloc(T, std.testing.allocator, value, &writer);
            try std.testing.expectEqual(hash.finalResult(), recordDigest(T, value));
        }
    };
    const Control = data.invocation.Control;
    const repeated: [1031]u8 = @splat(0x5a);
    for ([_][]const u8{ "", "reply bytes", repeated[0..200], &repeated }) |bytes| {
        try Oracle.expect(Control, .{ .reply = bytes });
        try Oracle.expect(Control, .{ .cancel = .{ .text = bytes } });
        try Oracle.expect(Control, .{ .cancel = .{ .bytes = bytes } });
    }
    try Oracle.expect(Control, .none);
    try Oracle.expect(Control, .resume_yield);
    const Wide = enum(u64) { a = 127, b = 128, c = 16383, d = 16384, e = std.math.maxInt(u64) };
    inline for (comptime std.enums.values(Wide)) |tag| try Oracle.expect(Wide, tag);
    const Open = enum(u8) { first = 255, second = 1, _ };
    for ([_]Open{ .first, .second, @fromBackingInt(128) }) |tag| try Oracle.expect(Open, tag);
    const Tag = enum(u16) { later = 300, earlier = 2 };
    const Tagged = union(Tag) { later: []const u8, earlier: u64 };
    try Oracle.expect(Tagged, .{ .later = "payload" });
    try Oracle.expect(Tagged, .{ .earlier = 1 << 40 });
    const Fact = @import("tasks/types.zig").CompilerFact;
    const Reference = @import("state.zig").Reference;
    const Context = struct { execution: Driver.Segment, guest_work: u64, outcome: Reference };
    const naturals = [_]u64{ 0, 1, 127, 128, 16383, 16384, 1 << 40, std.math.maxInt(u64) };
    for (naturals, 0..) |count, index| {
        const segment: Driver.Segment = .{
            .input = .{ .digest = @splat(1), .bytes = count },
            .image = .{ .digest = @splat(2), .bytes = naturals[naturals.len - 1 - index] },
            .runtime = @splat(3),
            .initial = index % 2 == 0,
            .control = @splat(4),
            .quantum = count,
        };
        try Oracle.expect(Driver.Segment, segment);
        try Oracle.expect(Context, .{
            .execution = segment,
            .guest_work = count,
            .outcome = .{ .digest = @splat(5), .bytes = count },
        });
        inline for (comptime std.enums.values(@FieldType(Fact, "kind"))) |kind| {
            try Oracle.expect(Fact, .{
                .kind = kind,
                .input = .{ .digest = @splat(6), .bytes = count },
                .output = .{ .digest = @splat(7), .bytes = count },
                .context = @splat(@truncate(index)),
            });
        }
    }
    for ([_][]const u8{ "", "abc", &repeated }) |bytes| {
        try std.testing.expectEqualDeep(
            kosmos.RuntimeCapsule.reference(bytes),
            capsuleReference(.of(bytes)),
        );
    }
}

fn yieldingImage() ![52]u8 {
    var image: [52]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &image,
        "41424c5f4250493303000000200000000000000001000001020a00000001000001000100" ++
            "00020000070100000000000000000000",
    );
    return image;
}

test "a drive's segment digests allocate nothing from the driver" {
    const a = std.testing.allocator;
    const image = try yieldingImage();
    const driver = try Driver.open(a, .of(&image), .{ .initial_args = &.{ 1, 42 } });
    defer driver.destroy() catch |err| {
        std.debug.panic("test driver destruction failed: {s}", .{@errorName(err)});
    };
    defer driver.close() catch |err| {
        std.debug.panic("test driver close failed: {s}", .{@errorName(err)});
    };
    var exhausted = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const parent = driver.storage().parent;
    driver.storage().parent = exhausted.allocator();
    defer driver.storage().parent = parent;
    for ([_]data.invocation.Control{ .none, .resume_yield }) |control| {
        const published = try driver.drive(a, control, 256);
        defer a.free(published.outcome);
        const segment = published.segment orelse return error.MissingSegment;
        const expected = recordDigest(data.invocation.Control, control);
        try std.testing.expectEqual(expected, segment.control);
    }
    try std.testing.expect(!exhausted.has_induced_failure);
}

test "driver retains publication across failed drive and transfers without allocation" {
    const a = std.testing.allocator;
    // Historical yielding bytes identity, also exercised by Kosmos's public
    // large-state restoration tests. The original image is not recompiled.
    const image = try yieldingImage();
    var failing = std.testing.FailingAllocator.init(a, .{});
    const driver = try Driver.open(
        failing.allocator(),
        .of(&image),
        .{ .initial_args = &.{ 1, 42 } },
    );
    defer driver.destroy() catch |err| {
        std.debug.panic("retired test driver destruction failed: {s}", .{@errorName(err)});
    };
    var statistics: kosmos.Statistics = .{};
    try driver.storage().resident.setStatistics(&statistics);
    const checkpoint = try expectInitialPublication(a, driver, &image);
    defer a.free(checkpoint);
    try std.testing.expectEqual(1, statistics.state_projections);
    const receipt = driver.storage().checkpoint.?;
    try std.testing.expectEqualSlices(u8, checkpoint, receipt.bytes());
    var no_output = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const origin = driver.storage().segment_origin.?;
    try std.testing.expectError(
        error.OutOfMemory,
        driver.drive(no_output.allocator(), .resume_yield, 256),
    );
    try std.testing.expectEqualDeep(origin, driver.storage().segment_origin.?);
    try std.testing.expectEqual(receipt, driver.storage().checkpoint.?);
    try std.testing.expectEqualSlices(u8, checkpoint, receipt.bytes());
    const continued = try driver.drive(a, .none, 0);
    defer a.free(continued.outcome);
    try std.testing.expectEqualDeep(
        kosmos.RuntimeCapsule.reference(checkpoint),
        continued.segment.?.input,
    );
    try std.testing.expect(!continued.segment.?.initial);
    try std.testing.expectEqual(@as(u64, 0), continued.segment.?.quantum);
    try std.testing.expectEqualDeep(
        kosmos.RuntimeCapsule.reference(continued.checkpoint),
        driver.storage().segment_origin.?.input,
    );
    const before = statistics.state_projections;
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try driver.retire();
    try std.testing.expectEqual(before, statistics.state_projections);
    try std.testing.expectError(error.InvalidState, driver.drive(a, .none, 0));
    try expectRestoredPublication(a, &image, checkpoint);
}

fn expectInitialPublication(a: std.mem.Allocator, driver: *Driver, image: []const u8) ![]u8 {
    var frame = std.heap.ArenaAllocator.init(a);
    defer frame.deinit();
    const published = try driver.drive(frame.allocator(), .none, 256);
    const segment = published.segment.?;
    try std.testing.expectEqualDeep(
        kosmos.RuntimeCapsule.reference(&.{ 1, 42 }),
        segment.input,
    );
    try std.testing.expectEqualDeep(kosmos.RuntimeCapsule.reference(image), segment.image);
    try std.testing.expectEqual(
        driver.storage().program.storage().prepared.runtime.identity,
        segment.runtime,
    );
    try std.testing.expect(segment.initial);
    try std.testing.expectEqual(@as(u64, 256), segment.quantum);
    const encoded_control = try @import("protean_contracts").encodeOwned(
        data.invocation.Control,
        frame.allocator(),
        .none,
    );
    try std.testing.expectEqual(
        kosmos.RuntimeCapsule.reference(encoded_control).digest,
        segment.control,
    );
    var outcome = try data.invocation.decode(data.invocation.Outcome, a, published.outcome);
    defer outcome.deinit();
    try std.testing.expect(outcome.value == .yielded);
    return a.dupe(u8, published.checkpoint);
}

fn expectRestoredPublication(
    a: std.mem.Allocator,
    image: []const u8,
    checkpoint: []const u8,
) !void {
    const restored = try Driver.open(a, .of(image), .{ .state = checkpoint });
    defer restored.destroy() catch |err| {
        std.debug.panic("closed test driver destruction failed: {s}", .{@errorName(err)});
    };
    const complete = try restored.drive(a, .resume_yield, 256);
    defer a.free(complete.outcome);
    try std.testing.expectEqualDeep(
        kosmos.RuntimeCapsule.reference(checkpoint),
        complete.segment.?.input,
    );
    try std.testing.expect(!complete.segment.?.initial);
    const encoded_control = try @import("protean_contracts").encodeOwned(
        data.invocation.Control,
        a,
        .resume_yield,
    );
    defer a.free(encoded_control);
    try std.testing.expectEqual(
        kosmos.RuntimeCapsule.reference(encoded_control).digest,
        complete.segment.?.control,
    );
    var outcome = try data.invocation.decode(data.invocation.Outcome, a, complete.outcome);
    defer outcome.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 1, 42 }, outcome.value.completed);
    try restored.close();
}
