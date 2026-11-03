const diagnostic_identity = [_]u8{ 0x10, 0x9e, 0x12, 0x33, 0x1e, 0xda, 0x6f, 0xc6, 0x5d, 0xba, 0xfb, 0x18, 0xf8, 0xf6, 0x7d, 0xfd, 0x9c, 0x1c, 0x59, 0x14, 0x7d, 0xa6, 0xd0, 0x4e, 0xa0, 0x4d, 0xa1, 0x01, 0x60, 0x8f, 0xdd, 0xcf };
const DiagnosticEntry = struct {
    token: u64 = 0,
    node: u64 = 0,
    function: u64 = 0,
    schema: u64 = 0,
    index: u64 = 0,
    kind: u64 = 0,
    blob: u64 = 0,
    length: u64 = 0,
    offset: u64 = 0,
};
const DiagnosticKey = struct { schema: u64, index: u64, kind: u64, length: u64, offset: u64 };
const DiagnosticCount = struct { key: DiagnosticKey, calls: u64 = 0, samples: u64 = 0 };
var diagnostic_next_token: u64 = 0;
var diagnostic_entries: [65536]DiagnosticEntry = @splat(.{});
var diagnostic_counts: [4096]?DiagnosticCount = @splat(null);
var diagnostic_steps: u64 = 0;
var diagnostic_samples: u64 = 0;
var diagnostic_missed: u64 = 0;
var diagnostic_invalid: u64 = 0;
var diagnostic_overflow: u64 = 0;
var diagnostic_truncated: u64 = 0;

fn diagnosticEntry(self: *Session, current: g.NodeRef, block: u64, frame: *bindings.Frame) void {
    if (!std.mem.eql(u8, &self.program_identity, &diagnostic_identity)) return;
    if (self.diagnostic_token == 0) {
        diagnostic_next_token +%= 1;
        self.diagnostic_token = diagnostic_next_token;
    }
    if (frame.position != 0) return;
    const function = self.program.blocks[@intCast(block)].function;
    if ((function != 173 and function != 165) or
        block != self.program.functions[@intCast(function)].entry) return;
    var entry: DiagnosticEntry = .{ .token = self.diagnostic_token, .node = current.id, .function = function };
    diagnosticExtract(self, frame, &entry) catch {
        diagnostic_invalid +|= 1;
        return;
    };
    diagnostic_entries[@intCast(current.id & 65535)] = entry;
    if (function == 173) diagnosticCount(.{
        .schema = entry.schema,
        .index = entry.index,
        .kind = entry.kind,
        .length = 64,
        .offset = 64,
    }, true);
}

fn diagnosticCount(key: DiagnosticKey, call: bool) void {
    const hash = key.schema *% 0x9e3779b97f4a7c15 ^ key.index *% 0x517cc1b727220a95 ^
        key.kind *% 257 ^ key.length *% 17 ^ key.offset;
    for (0..diagnostic_counts.len) |delta| {
        const slot: usize = @intCast((hash +% delta) & (diagnostic_counts.len - 1));
        if (diagnostic_counts[slot] == null) diagnostic_counts[slot] = .{ .key = key };
        const item = &diagnostic_counts[slot].?;
        if (std.meta.eql(item.key, key)) {
            if (call) item.calls +|= 1 else item.samples +|= 1;
            return;
        }
    }
    diagnostic_overflow +|= 1;
}

fn diagnosticBucket(value: u64) u64 {
    return if (value == 0) 0 else 64 - @clz(value);
}

fn diagnosticSample(self: *const Session, current: g.NodeRef) void {
    if (self.transitions & 1023 != 0 or
        !std.mem.eql(u8, &self.program_identity, &diagnostic_identity)) return;
    var next: ?g.NodeRef = current;
    var selected: ?DiagnosticEntry = null;
    var scan: ?DiagnosticEntry = null;
    for (0..128) |_| {
        const reference = next orelse break;
        const node = self.store.get(reference) catch {
            diagnostic_invalid +|= 1;
            break;
        };
        const block = switch (node) {
            .control => |item| found: {
                next = item.parent;
                break :found item.block;
            },
            .continuation => |item| found: {
                next = item.parent;
                break :found item.source_block;
            },
            else => {
                diagnostic_invalid +|= 1;
                break;
            },
        };
        if (block >= self.program.blocks.len) break;
        const function = self.program.blocks[@intCast(block)].function;
        if (function != 173 and function != 165) continue;
        const entry = diagnostic_entries[@intCast(reference.id & 65535)];
        if (entry.token != self.diagnostic_token or entry.node != reference.id or entry.function != function) {
            diagnostic_missed +|= 1;
            continue;
        }
        if (function == 165 and scan == null) scan = entry;
        if (function == 173) {
            selected = entry;
            next = null;
            break;
        }
    }
    if (next != null) diagnostic_truncated +|= 1;
    if (selected) |entry| diagnosticCount(.{
        .schema = entry.schema,
        .index = entry.index,
        .kind = entry.kind,
        .length = if (scan) |item| diagnosticBucket(item.length) else 63,
        .offset = if (scan) |item| diagnosticBucket(item.offset) else 63,
    }, false);
    diagnostic_samples +|= 1;
}

fn diagnosticStep(self: *const Session) void {
    if (!std.mem.eql(u8, &self.program_identity, &diagnostic_identity)) return;
    diagnostic_steps +%= 1;
    if (diagnostic_steps & ((1 << 20) - 1) == 0) diagnosticDump();
}

pub fn diagnosticDump() void {
    std.debug.print("field-counts steps={d} samples={d} missing={d} invalid={d} overflow={d} truncated={d}\n", .{
        diagnostic_steps, diagnostic_samples, diagnostic_missed, diagnostic_invalid, diagnostic_overflow, diagnostic_truncated,
    });
    for (&diagnostic_counts) |*row| {
        if (row.*) |item| std.debug.print("field-work schema={d} index={d} kind={d} length_bucket={d} offset_bucket={d} calls={d} samples={d}\n", .{
            item.key.schema, item.key.index, item.key.kind, item.key.length, item.key.offset, item.calls, item.samples,
        });
        row.* = null;
    }
    diagnostic_samples = 0;
    diagnostic_missed = 0;
    diagnostic_invalid = 0;
    diagnostic_overflow = 0;
    diagnostic_truncated = 0;
}

fn diagnosticExtract(self: *Session, frame: *bindings.Frame, entry: *DiagnosticEntry) !void {
    const extract = @import("diagnostic_fields.zig");
    const reader = try self.frames.slots.reader(frame.view);
    if (entry.function == 173) {
        const value = extract.guestValue(&self.store, try read(reader, 1)) orelse return error.DiagnosticValue;
        entry.schema = value.schema;
        entry.kind = value.kind;
        entry.blob = value.blob_id orelse 0;
        entry.index = extract.scalarU64(&self.store, try read(reader, 2)) orelse return error.DiagnosticIndex;
    } else {
        entry.length = extract.bytesLength(&self.store, try read(reader, 2)) orelse return error.DiagnosticBytes;
        entry.offset = extract.scalarU64(&self.store, try read(reader, 3)) orelse return error.DiagnosticOffset;
    }
}
