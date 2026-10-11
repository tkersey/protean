//! A separately compiled, bounded byte/LF fold with owned effectful retirement.
const std = @import("std");
const horos = @import("horos");
const source = horos.source;
const data = horos.data;
const contracts = @import("protean_contracts");
const a = horos.authoring;
pub const chunk_bytes = 16;
pub const maximum_subject_bytes = 65536;
pub const Subject = struct { name: contracts.Text(64), version: [32]u8, length: u64 };
pub const Read = struct { subject: Subject, offset: u64, maximum: u64 };
pub const Chunk = struct { version: [32]u8, offset: u64, bytes: contracts.Bytes(chunk_bytes), eof: bool };
pub const Reply = union(enum) { chunk: Chunk, unavailable, changed, cancelled };
pub const Stats = struct { bytes: u64, newlines: u64 };
pub const Result = union(enum) { ok: Stats, unavailable, changed, cancelled, invalid_reply };
pub const read_identity = "agent.text.read-chunk.v1";
pub const close_identity = "agent.text.close.v1";
pub const name = "inspect_text";
pub const description = "Count bytes and LF newlines in a declared immutable text subject";

const Emit = struct {
    c: *a.Context,
    unit: *const a.Schema,
    integer: *const a.Schema,
    failure: *const a.FailureLiteral,
    fn schema(e: Emit, comptime T: type) !*const a.Schema {
        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                if (@hasDecl(T, "protean_value_kind")) return a.interop.schema(e.c, try contracts.schema(T, a.interop.builder(e.c)));
                var fields: [info.field_names.len]a.Field = undefined;
                inline for (info.field_names, info.field_types, 0..) |field_name, FieldType, i| fields[i] = .{ .name = field_name, .schema = try e.schema(FieldType) };
                return e.c.record(&fields);
            },
            .@"union" => |info| {
                var fields: [info.field_names.len]a.Field = undefined;
                inline for (info.field_names, info.field_types, 0..) |field_name, FieldType, i| fields[i] = .{ .name = field_name, .schema = try e.schema(FieldType) };
                return e.c.alternatives(&fields);
            },
            else => return a.interop.schema(e.c, try contracts.schema(T, a.interop.builder(e.c))),
        }
    }
    fn add(e: Emit, body: *a.Body, left: *const a.Value, right: *const a.Value) !*const a.Value {
        return body.checkedAdd(left, right, e.failure);
    }
    fn rejected(e: Emit, body: *a.Body, tag: []const u8) !*const a.Value {
        return body.variant(try e.schema(Result), tag, try body.constant(void, {}));
    }
    const Guard = struct {
        e: Emit,
        parent: *a.Body,
        condition: *const a.Value,
        work: *a.Body,
        invalid: *a.Body,
        accepts_true: bool,
        fn finish(g: @This(), value: *const a.Value) !*const a.Value {
            const yes = try g.work.ret(value);
            const no = try g.invalid.ret(try g.e.rejected(g.invalid, "invalid_reply"));
            return g.parent.conditional(g.condition, if (g.accepts_true) yes else no, if (g.accepts_true) no else yes);
        }
    };
    fn guard(e: Emit, work: **a.Body, guards: *std.ArrayList(Guard), condition: *const a.Value, accepts_true: bool) !void {
        const parent = work.*;
        const valid = try parent.branch();
        try guards.append(a.interop.builder(e.c).allocator(), .{ .e = e, .parent = parent, .condition = condition, .work = valid, .invalid = try parent.branch(), .accepts_true = accepts_true });
        work.* = valid;
    }
};

fn counter(e: Emit) !*const a.Function {
    const c = e.c;
    const function = try c.function("count LF bytes", &.{ .{ .name = "bytes", .schema = try e.schema(contracts.Bytes(chunk_bytes)) }, .{ .name = "index", .schema = e.integer }, .{ .name = "count", .schema = e.integer } }, e.integer, &.{});
    const body = try c.body(function);
    const value = try body.parameter("bytes");
    const index = try body.parameter("index");
    const count = try body.parameter("count");
    const active = try body.branch();
    const ended = try body.branch();
    const byte = try active.blobByte(value, index);
    const missing = try active.caseOf(byte, "none");
    const present = try active.caseOf(byte, "some");
    const some = present.body();
    const next = try e.add(some, index, try some.constant(u64, 1));
    const newline = try some.branch();
    const ordinary = try some.branch();
    const yes = try newline.call(function, &.{ .{ .name = "bytes", .value = value }, .{ .name = "index", .value = next }, .{ .name = "count", .value = try e.add(newline, count, try newline.constant(u64, 1)) } });
    const no = try ordinary.call(function, &.{ .{ .name = "bytes", .value = value }, .{ .name = "index", .value = next }, .{ .name = "count", .value = count } });
    const counted = try some.conditional(try some.equal(present.payload(), try some.constant(u8, 10)), try newline.ret(yes), try ordinary.ret(no));
    const selected = try active.match(byte, &.{ try missing.fail(e.integer, try missing.body().constant(void, {})), try present.ret(counted) });
    try c.define(function, try body.ret(try body.conditional(try body.less(index, try body.blobLength(value)), try active.ret(selected), try ended.ret(count))));
    return function;
}

fn versionEquality(e: Emit) !*const a.Function {
    const c = e.c;
    const version = try e.schema([32]u8);
    const boolean = try c.scalar(bool);
    const function = try c.function("compare versions", &.{ .{ .name = "left", .schema = version }, .{ .name = "right", .schema = version }, .{ .name = "index", .schema = e.integer } }, boolean, &.{});
    const body = try c.body(function);
    const left = try body.parameter("left");
    const right = try body.parameter("right");
    const index = try body.parameter("index");
    const active = try body.branch();
    const ended = try body.branch();
    const l = try active.sequenceGet(left, index);
    const l_none = try active.caseOf(l, "none");
    const l_some = try active.caseOf(l, "some");
    const r = try l_some.body().sequenceGet(right, index);
    const r_none = try l_some.body().caseOf(r, "none");
    const r_some = try l_some.body().caseOf(r, "some");
    const equal = try r_some.body().branch();
    const different = try r_some.body().branch();
    const next = try equal.call(function, &.{ .{ .name = "left", .value = left }, .{ .name = "right", .value = right }, .{ .name = "index", .value = try e.add(equal, index, try equal.constant(u64, 1)) } });
    const compared = try r_some.body().conditional(try r_some.body().equal(l_some.payload(), r_some.payload()), try equal.ret(next), try different.ret(try different.constant(bool, false)));
    const right_match = try l_some.body().match(r, &.{ try r_none.fail(boolean, try r_none.body().constant(void, {})), try r_some.ret(compared) });
    const left_match = try active.match(l, &.{ try l_none.fail(boolean, try l_none.body().constant(void, {})), try l_some.ret(right_match) });
    try c.define(function, try body.ret(try body.conditional(try body.less(index, try body.constant(u64, 32)), try active.ret(left_match), try ended.ret(try ended.constant(bool, true)))));
    return function;
}

fn fold(e: Emit, read: *const a.Operation) !*const a.Function {
    const c = e.c;
    const function = try c.function("inspect chunks", &.{ .{ .name = "subject", .schema = try e.schema(Subject) }, .{ .name = "offset", .schema = e.integer }, .{ .name = "lines", .schema = e.integer } }, try e.schema(Result), &.{read});
    const count = try counter(e);
    const versions = try versionEquality(e);
    const body = try c.body(function);
    const subject = try body.parameter("subject");
    const offset = try body.parameter("offset");
    const lines = try body.parameter("lines");
    const request = try body.product(try e.schema(Read), &.{ .{ .name = "subject", .value = subject }, .{ .name = "offset", .value = offset }, .{ .name = "maximum", .value = try body.constant(u64, chunk_bytes) } });
    const reply = try body.perform(read, request);
    const chunk = try body.caseOf(reply, "chunk");
    var work = chunk.body();
    var guards: std.ArrayList(Emit.Guard) = .empty;
    defer guards.deinit(a.interop.builder(c).allocator());
    const value = chunk.payload();
    const same_version = try work.call(versions, &.{ .{ .name = "left", .value = try work.field(value, "version") }, .{ .name = "right", .value = try work.field(subject, "version") }, .{ .name = "index", .value = try work.constant(u64, 0) } });
    try e.guard(&work, &guards, same_version, true);
    try e.guard(&work, &guards, try work.equal(try work.field(value, "offset"), offset), true);
    const content = try work.field(value, "bytes");
    const size = try work.blobLength(content);
    const eof = try work.field(value, "eof");
    const zero = try work.branch();
    const nonzero = try work.branch();
    const progress = try work.conditional(try work.equal(size, try work.constant(u64, 0)), try zero.ret(eof), try nonzero.ret(try nonzero.constant(bool, true)));
    try e.guard(&work, &guards, progress, true);
    const next = try e.add(work, offset, size);
    const total = try work.field(subject, "length");
    try e.guard(&work, &guards, try work.less(total, next), false);
    try e.guard(&work, &guards, try work.equal(eof, try work.equal(next, total)), true);
    const counted = try work.call(count, &.{ .{ .name = "bytes", .value = content }, .{ .name = "index", .value = try work.constant(u64, 0) }, .{ .name = "count", .value = lines } });
    const done = try work.branch();
    const more = try work.branch();
    const stats = try done.product(try e.schema(Stats), &.{ .{ .name = "bytes", .value = next }, .{ .name = "newlines", .value = counted } });
    const continued = try more.call(function, &.{ .{ .name = "subject", .value = subject }, .{ .name = "offset", .value = next }, .{ .name = "lines", .value = counted } });
    var result = try work.conditional(eof, try done.ret(try done.variant(try e.schema(Result), "ok", stats)), try more.ret(continued));
    var remaining = guards.items.len;
    while (remaining != 0) {
        remaining -= 1;
        result = try guards.items[remaining].finish(result);
    }
    const unavailable = try body.caseOf(reply, "unavailable");
    const changed = try body.caseOf(reply, "changed");
    const cancelled = try body.caseOf(reply, "cancelled");
    try c.define(function, try body.ret(try body.match(reply, &.{ try chunk.ret(result), try unavailable.ret(try e.rejected(unavailable.body(), "unavailable")), try changed.ret(try e.rejected(changed.body(), "changed")), try cancelled.ret(try e.rejected(cancelled.body(), "cancelled")) })));
    return function;
}

pub fn emit(allocator: std.mem.Allocator) ![]u8 {
    var b = source.Builder.init(allocator);
    defer b.deinit();
    const c = try a.Context.init(&b);
    const e: Emit = .{ .c = c, .unit = try c.scalar(void), .integer = try c.scalar(u64), .failure = try c.literalFailure(void, {}) };
    const subject_schema = try e.schema(Subject);
    const result_schema = try e.schema(Result);
    const read = try c.external(read_identity, try e.schema(Read), try e.schema(Reply));
    const close = try c.external(close_identity, subject_schema, e.unit);
    const loop = try fold(e, read);
    const generator = try horos.library.generator.create(c, "agent.text.result.v1", e.unit, result_schema, e.unit, .{
        .captures = .{ .continuation = &.{ e.unit, e.integer, subject_schema, result_schema, try e.schema(Read), try e.schema(Reply), try e.schema(Chunk), try e.schema(Stats), try e.schema([32]u8), try e.schema(contracts.Bytes(chunk_bytes)), try c.scalar(bool), try c.scalar(u8) }, .body = &.{subject_schema} },
        .residual = &.{ read, close },
        .body_use = .reusable,
    });
    const main = try c.function("inspect text", &.{.{ .name = "subject", .schema = subject_schema }}, result_schema, &.{ read, close });
    const entry = try c.body(main);
    const subject = try entry.parameter("subject");
    const invalid = try entry.branch();
    const valid = try entry.branch();
    const start_type = try c.handledSchema(generator.handler());
    const start_fn = try c.functionFor("owned text inspection", start_type);
    const start = try valid.closureBody(start_fn);
    const capability = try start.parameter("capability");
    const work_type = try c.callable(&.{}, e.unit, &.{ read, generator.effect() }, .{ .use = .reusable, .captures = &.{ subject_schema, generator.capability() } });
    const work_fn = try c.functionFor("read and offer", work_type);
    const work = try start.closureBody(work_fn);
    const result = try work.call(loop, &.{ .{ .name = "subject", .value = subject }, .{ .name = "offset", .value = try work.constant(u64, 0) }, .{ .name = "lines", .value = try work.constant(u64, 0) } });
    _ = try work.performLocal(generator.effect(), capability, result);
    try c.define(work_fn, try work.ret(try work.constant(void, {})));
    const cleanup_type = try c.callable(&.{.{ .name = "exit", .schema = try c.cleanupInfo(e.unit) }}, e.unit, &.{close}, .{ .use = .reusable, .captures = &.{subject_schema} });
    const cleanup_fn = try c.functionFor("close text subject", cleanup_type);
    const cleanup = try start.closureBody(cleanup_fn);
    try c.define(cleanup_fn, try cleanup.ret(try cleanup.perform(close, subject)));
    try c.define(start_fn, try start.ret(try start.protect(try start.lambda(work_fn, work_type), try start.lambda(cleanup_fn, cleanup_type), &.{})));
    const answer = try valid.handleWith(generator.handler(), try valid.lambda(start_fn, start_type), &.{});
    const done = try valid.caseOf(answer, "done");
    const yielded = try valid.caseOf(answer, "yielded");
    const parts = try yielded.body().destructure(yielded.payload());
    const returned = try parts.get("value");
    _ = try yielded.body().disposePackage(try parts.get("future"));
    const handled = try valid.match(answer, &.{ try done.ret(try e.rejected(done.body(), "invalid_reply")), try yielded.ret(returned) });
    try c.define(main, try entry.ret(try entry.conditional(try entry.less(try entry.constant(u64, maximum_subject_bytes), try entry.field(subject, "length")), try invalid.ret(try e.rejected(invalid, "invalid_reply")), try valid.ret(handled))));
    var compiled = try source.component.compile(allocator, try c.module(main, e.unit), .{
        .imports = &.{ .{ .name = "read", .reference = .{ .kind = .effect, .id = try a.interop.operationId(c, read) } }, .{ .name = "close", .reference = .{ .kind = .effect, .id = try a.interop.operationId(c, close) } } },
        .exports = &.{.{ .name = "inspect", .reference = .{ .kind = .function, .id = try a.interop.functionId(c, main) } }},
    });
    defer compiled.deinit();
    const bytes = try allocator.alloc(u8, try data.component.encodedLength(compiled.object));
    errdefer allocator.free(bytes);
    _ = try compiled.encode(allocator, bytes);
    return bytes;
}
