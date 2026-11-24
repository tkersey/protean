const std = @import("std");
const horos = @import("horos");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const example = @import("projection_example");
const wc = contracts.workspace;
const Allocator = std.mem.Allocator;

pub const Seed = enum { lossy, adequate };
pub const ScanEvidence = example.ScanEvidence;

pub fn fixtureForwarder(a: Allocator) ![]u8 {
    var b = horos.source.Builder.init(a);
    defer b.deinit();
    const input = try contracts.schema(wc.ProjectionInput(ScanEvidence), &b);
    const output = try contracts.schema(wc.ProjectionResult(ScanEvidence), &b);
    const entry = try b.declare(&.{input}, output, &.{}, &.{});
    const argument = try b.reference(b.parameter(entry, 0));
    const ref = try b.primitive(try contracts.schema(wc.Ref, &b), .field, &.{argument}, 0);
    const value = try b.primitive(try contracts.schema(ScanEvidence, &b), .field, &.{argument}, 1);
    const Blocks = contracts.Vector(wc.PresentationBlock, null);
    const blocks = try b.literal(.{
        .schema = try contracts.schema(Blocks, &b),
        .bytes = try contracts.encodeOwned(Blocks, b.allocator(), .{
            .items = &.{.{ .computed = .{} }},
        }),
    });
    const proposal_schema = try contracts.schema(wc.ProjectionProposal, &b);
    const proposal = try b.primitive(proposal_schema, .product, &.{ ref, blocks }, 0);
    try b.define(entry, try b.pure(try b.primitive(output, .product, &.{ proposal, value }, 0)));
    return native.source_records.encode(a, b.module(entry, try b.scalar(void)));
}

pub fn seed(a: Allocator, kind: Seed) ![]u8 {
    const program: example.Program = switch (kind) {
        .lossy => .bad_projector,
        .adequate => .repaired_projector,
    };
    const original = try example.source(a, program);
    defer a.free(original);
    var decoded = try native.source_records.decode(a, original);
    defer decoded.deinit();
    var extracted = try horos.source.slice.extract(a, decoded.module, .{
        .entry = decoded.module.entry,
        .require_pure = true,
    });
    defer extracted.deinit();
    if (kind == .lossy) {
        const kept = [_]?horos.source.Id{ 0, null, null, null, 1, null, 2 };
        if (!std.mem.eql(?horos.source.Id, &kept, extracted.maps.functions))
            return error.PrivateClassifierDependency;
    }
    const bytes = try native.source_records.encode(a, extracted.module());
    errdefer a.free(bytes);
    if (kind == .lossy) try checkLossy(a, bytes);
    return bytes;
}

pub fn checkLossy(a: Allocator, bytes: []const u8) !void {
    var decoded = try native.source_records.decode(a, bytes);
    defer decoded.deinit();
    const module = decoded.module;
    if (module.functions.len != 3 or module.entry != 2 or module.effects.len != 0)
        return error.PrivateClassifierDependency;
    var extracted = try horos.source.slice.extract(a, module, .{
        .entry = module.entry,
        .require_pure = true,
    });
    defer extracted.deinit();
    const reachable = try native.source_records.encode(a, extracted.module());
    defer a.free(reachable);
    if (!std.mem.eql(u8, bytes, reachable)) return error.UnreachableSeedMaterial;
    const Blocks = contracts.Vector(wc.PresentationBlock, null);
    const computed = try contracts.encodeOwned(Blocks, a, .{ .items = &.{.{ .computed = .{} }} });
    defer a.free(computed);
    for (module.constants) |literal| {
        const allowed = switch (module.schemas[@intCast(literal.schema)]) {
            .unit => literal.bytes.len == 0,
            .boolean, .product => literal.bytes.len == 1 and literal.bytes[0] <= 1,
            .u64 => literal.bytes.len == 8 and
                std.mem.readInt(u64, literal.bytes[0..8], .little) <= 1,
            .seq => std.mem.eql(u8, computed, literal.bytes),
            else => false,
        };
        if (!allowed) return error.PrivateSeedConstant;
    }
}

pub const Acquired = struct { reference: wc.Ref, bytes: []const u8 };
pub const Scan = struct { evidence: example.ScanEvidence, sources: []const wc.Ref };
const VisitSource = struct {
    domain_identity: u64,
    domain_revision: u64,
    member: u64,
    path: contracts.Utf8,
};
const Manifest = struct { domain: example.Domain, visits: contracts.Vector(VisitSource, null) };

pub fn acquireScan(arena: Allocator, owner: anytype) !Scan {
    return acquireScanAt(arena, owner, .primary);
}

pub const ManifestSelection = enum { primary, paired };

pub fn acquireScanAt(arena: Allocator, owner: anytype, selected: ManifestSelection) !Scan {
    const name = switch (selected) {
        .primary => "scan.json",
        .paired => "paired-scan.json",
    };
    const manifest = try owner.acquireFile(name) orelse return error.MissingScanDeclaration;
    var parsed = try native.json.parseAsset(arena, manifest.bytes, manifest.bytes.len);
    defer parsed.deinit();
    const declared = try native.values.fromJson(Manifest, arena, parsed.value);
    const visits = try arena.alloc(example.Visit, declared.visits.items.len);
    var sources: std.ArrayList(wc.Ref) = .empty;
    try sources.append(arena, manifest.reference);
    for (declared.visits.items, visits) |visit, *target| {
        if (!sourcePath(visit.path.bytes)) return error.InvalidScanPath;
        const record = try owner.acquireFile(visit.path.bytes);
        target.* = .{
            .domain_identity = visit.domain_identity,
            .domain_revision = visit.domain_revision,
            .member = visit.member,
            .available = record != null,
            .observed = if (record) |r| try native.json.decimal(u64, .{ .string = r.bytes }) else 0,
            .evidence = if (record) |r| r.reference else manifest.reference,
        };
        if (record) |r| try sources.append(arena, r.reference);
    }
    return .{
        .evidence = .{ .domain = declared.domain, .visits = .{ .items = visits } },
        .sources = sources.items,
    };
}

pub fn projectionInput(a: Allocator, consumer: wc.Ref, evidence: example.ScanEvidence) ![]u8 {
    const T = wc.ProjectionInput(example.ScanEvidence);
    const schema = try native.values.schemaBytes(T, a);
    defer a.free(schema);
    const encoded = try contracts.encodeOwned(T, a, .{ .consumer = consumer, .value = evidence });
    defer a.free(encoded);
    var decoded = try native.dynamic_values.decode(a, schema, encoded);
    defer decoded.deinit();
    return native.json.canonical(a, decoded.value);
}

pub fn requireComputed(
    a: Allocator,
    consumer: wc.Ref,
    schema: []const u8,
    bytes: []const u8,
) !void {
    var decoded = try native.projection_proposal.decodeResult(a, schema, bytes);
    defer decoded.deinit();
    const proposal = decoded.header;
    if (proposal.consumer.kind != .observation or
        !std.mem.eql(u8, proposal.consumer.id.bytes, consumer.id.bytes) or
        proposal.blocks.items.len != 1 or proposal.blocks.items[0] != .computed)
        return error.ProjectionResultRejected;
}

fn sourcePath(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "r-") or path.len == 2) return false;
    for (path[2..]) |b| if (!std.ascii.isAlphanumeric(b) and b != '-') return false;
    return true;
}
