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
pub const Chunk = struct {
    version: [32]u8,
    offset: u64,
    bytes: contracts.Bytes(chunk_bytes),
    eof: bool,
};
pub const Reply = union(enum) { chunk: Chunk, unavailable, changed, cancelled };
pub const Stats = struct { bytes: u64, newlines: u64 };
pub const Result = union(enum) { ok: Stats, unavailable, changed, cancelled, invalid_reply };
pub const read_identity = "agent.text.read-chunk.v1";
pub const close_identity = "agent.text.close.v1";
pub const name = "inspect_text";
pub const description = "Count bytes and LF newlines in a declared immutable text subject";

const native = data.schema.native;
fn V(comptime T: type) type {
    return *const a.Value(a.Shape(T));
}
fn F(comptime Input: type, comptime Output: type) type {
    return *const a.Function(a.Signature(a.Shape(Input).contract.product, a.Shape(Output)));
}
const Branch = a.Body(native.Fields(&.{}, &.{}));
const Emit = struct {
    c: *a.Context,
    unit: *const a.Schema(a.Shape(void)),
    integer: *const a.Schema(a.Shape(u64)),
    failure: *const a.FailureLiteral(a.Shape(void)),
    fn add(e: Emit, body: anytype, left: V(u64), right: V(u64)) !V(u64) {
        return body.checkedAdd(left, right, e.failure);
    }
    fn rejected(e: Emit, body: anytype, comptime tag: []const u8) !V(Result) {
        return body.variant(try e.c.schema(Result), tag, try body.constant(void, {}));
    }
    const Guard = struct {
        e: Emit,
        parent: *Branch,
        condition: V(bool),
        work: *Branch,
        invalid: *Branch,
        accepts_true: bool,
        fn finish(g: @This(), value: V(Result)) !V(Result) {
            const yes = try g.work.ret(value);
            const no = try g.invalid.ret(try g.e.rejected(g.invalid, "invalid_reply"));
            return g.parent.conditional(
                g.condition,
                if (g.accepts_true) yes else no,
                if (g.accepts_true) no else yes,
            );
        }
    };
    fn guard(
        e: Emit,
        work: **Branch,
        guards: *std.ArrayList(Guard),
        condition: V(bool),
        accepts_true: bool,
    ) !void {
        const parent = work.*;
        const valid = try parent.branch();
        try guards.append(a.interop.builder(e.c).allocator(), .{
            .e = e,
            .parent = parent,
            .condition = condition,
            .work = valid,
            .invalid = try parent.branch(),
            .accepts_true = accepts_true,
        });
        work.* = valid;
    }
};

fn counter(
    e: Emit,
) !F(struct { bytes: contracts.Bytes(chunk_bytes), index: u64, count: u64 }, u64) {
    const c = e.c;
    const function = try c.function("count LF bytes", .{
        .bytes = try e.c.schema(contracts.Bytes(chunk_bytes)),
        .index = e.integer,
        .count = e.integer,
    }, e.integer, &.{});
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
    const yes = try newline.call(function, .{
        .bytes = value,
        .index = next,
        .count = try e.add(newline, count, try newline.constant(u64, 1)),
    });
    const no = try ordinary.call(function, .{ .bytes = value, .index = next, .count = count });
    const counted = try some.conditional(
        try some.equal(present.payload(), try some.constant(u8, 10)),
        try newline.ret(yes),
        try ordinary.ret(no),
    );
    const selected = try active.match(byte, .{
        .none = try missing.fail(e.integer, try missing.body().constant(void, {})),
        .some = try present.ret(counted),
    });
    try c.define(
        function,
        try body.ret(
            try body.conditional(
                try body.less(index, try body.blobLength(value)),
                try active.ret(selected),
                try ended.ret(count),
            ),
        ),
    );
    return function;
}

fn versionEquality(e: Emit) !F(struct { left: [32]u8, right: [32]u8, index: u64 }, bool) {
    const c = e.c;
    const version = try e.c.schema([32]u8);
    const boolean = try c.schema(bool);
    const function = try c.function("compare versions", .{
        .left = version,
        .right = version,
        .index = e.integer,
    }, boolean, &.{});
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
    const next = try equal.call(function, .{
        .left = left,
        .right = right,
        .index = try e.add(equal, index, try equal.constant(u64, 1)),
    });
    const compared = try r_some.body().conditional(
        try r_some.body().equal(l_some.payload(), r_some.payload()),
        try equal.ret(next),
        try different.ret(try different.constant(bool, false)),
    );
    const right_match = try l_some.body().match(r, .{
        .none = try r_none.fail(boolean, try r_none.body().constant(void, {})),
        .some = try r_some.ret(compared),
    });
    const left_match = try active.match(l, .{
        .none = try l_none.fail(boolean, try l_none.body().constant(void, {})),
        .some = try l_some.ret(right_match),
    });
    try c.define(
        function,
        try body.ret(
            try body.conditional(
                try body.less(index, try body.constant(u64, 32)),
                try active.ret(left_match),
                try ended.ret(try ended.constant(bool, true)),
            ),
        ),
    );
    return function;
}

fn fold(e: Emit, read: anytype) !F(struct { subject: Subject, offset: u64, lines: u64 }, Result) {
    const c = e.c;
    const function = try c.function("inspect chunks", .{
        .subject = try e.c.schema(Subject),
        .offset = e.integer,
        .lines = e.integer,
    }, try e.c.schema(Result), &.{read});
    const count = try counter(e);
    const versions = try versionEquality(e);
    const body = try c.body(function);
    const subject = try body.parameter("subject");
    const offset = try body.parameter("offset");
    const lines = try body.parameter("lines");
    const request = try body.product(try e.c.schema(Read), .{
        .subject = subject,
        .offset = offset,
        .maximum = try body.constant(u64, chunk_bytes),
    });
    const reply = try body.perform(read, request);
    const chunk = try body.caseOf(reply, "chunk");
    const result = try chunkResult(e, .{
        .chunk = chunk,
        .versions = versions,
        .subject = subject,
        .offset = offset,
        .count = count,
        .lines = lines,
        .function = function,
    });
    const unavailable = try body.caseOf(reply, "unavailable");
    const changed = try body.caseOf(reply, "changed");
    const cancelled = try body.caseOf(reply, "cancelled");
    try c.define(
        function,
        try body.ret(
            try body.match(reply, .{
                .chunk = try chunk.ret(result),
                .unavailable = try unavailable.ret(
                    try e.rejected(unavailable.body(), "unavailable"),
                ),
                .changed = try changed.ret(try e.rejected(changed.body(), "changed")),
                .cancelled = try cancelled.ret(try e.rejected(cancelled.body(), "cancelled")),
            }),
        ),
    );
    return function;
}

pub fn emit(allocator: std.mem.Allocator) ![]u8 {
    var b = source.Builder.init(allocator);
    defer b.deinit();
    const c = try a.Context.init(&b);
    const e: Emit = .{
        .c = c,
        .unit = try c.schema(void),
        .integer = try c.schema(u64),
        .failure = try c.literalFailure(void, {}),
    };
    const subject_schema = try e.c.schema(Subject);
    const result_schema = try e.c.schema(Result);
    const read = try c.external(read_identity, try e.c.schema(Read), try e.c.schema(Reply));
    const close = try c.external(close_identity, subject_schema, e.unit);
    const loop = try fold(e, read);
    const generator = try horos.library.generator.create(
        c,
        "agent.text.result.v1",
        e.unit,
        result_schema,
        e.unit,
        .{
            .captures = .{ .continuation = .{
                e.unit,
                e.integer,
                subject_schema,
                result_schema,
                try e.c.schema(Read),
                try e.c.schema(Reply),
                try e.c.schema(Chunk),
                try e.c.schema(Stats),
                try e.c.schema([32]u8),
                try e.c.schema(contracts.Bytes(chunk_bytes)),
                try c.schema(bool),
                try c.schema(u8),
            }, .body = .{subject_schema} },
            .residual = .{ read, close },
            .body_use = .reusable,
        },
    );
    const main = try defineMain(e, .{
        .subject_schema = subject_schema,
        .result_schema = result_schema,
        .read = read,
        .close = close,
        .loop = loop,
        .generator = generator,
    });
    return encodeComponent(allocator, e, .{ .read = read, .close = close, .main = main });
}

fn chunkResult(e: Emit, s: anytype) !V(Result) {
    var work = s.chunk.body();
    var guards: std.ArrayList(Emit.Guard) = .empty;
    defer guards.deinit(a.interop.builder(e.c).allocator());
    const value = s.chunk.payload();
    const same_version = try work.call(s.versions, .{
        .left = try work.field(value, "version"),
        .right = try work.field(s.subject, "version"),
        .index = try work.constant(u64, 0),
    });
    try e.guard(&work, &guards, same_version, true);
    try e.guard(&work, &guards, try work.equal(try work.field(value, "offset"), s.offset), true);
    const content = try work.field(value, "bytes");
    const size = try work.blobLength(content);
    const eof = try work.field(value, "eof");
    const zero = try work.branch();
    const nonzero = try work.branch();
    const progress = try work.conditional(
        try work.equal(size, try work.constant(u64, 0)),
        try zero.ret(eof),
        try nonzero.ret(try nonzero.constant(bool, true)),
    );
    try e.guard(&work, &guards, progress, true);
    const next = try e.add(work, s.offset, size);
    const total = try work.field(s.subject, "length");
    try e.guard(&work, &guards, try work.less(total, next), false);
    try e.guard(&work, &guards, try work.equal(eof, try work.equal(next, total)), true);
    const counted = try work.call(s.count, .{
        .bytes = content,
        .index = try work.constant(u64, 0),
        .count = s.lines,
    });
    const done = try work.branch();
    const more = try work.branch();
    const stats = try done.product(try e.c.schema(Stats), .{ .bytes = next, .newlines = counted });
    const continued = try more.call(s.function, .{
        .subject = s.subject,
        .offset = next,
        .lines = counted,
    });
    var result = try work.conditional(
        eof,
        try done.ret(try done.variant(try e.c.schema(Result), "ok", stats)),
        try more.ret(continued),
    );
    var remaining = guards.items.len;
    while (remaining != 0) {
        remaining -= 1;
        result = try guards.items[remaining].finish(result);
    }
    return result;
}

fn defineMain(e: Emit, s: anytype) !F(struct { subject: Subject }, Result) {
    const c = e.c;
    const main = try c.function("inspect text", .{
        .subject = s.subject_schema,
    }, s.result_schema, .{ s.read, s.close });
    const entry = try c.body(main);
    const subject = try entry.parameter("subject");
    const invalid = try entry.branch();
    const valid = try entry.branch();
    const start_type = try c.handledSchema(s.generator.handler());
    const start_fn = try c.functionFor("owned text inspection", start_type);
    const start = try valid.closureBody(start_fn);
    const capability = try start.parameter("capability");
    const work_type = try c.callable(.{}, e.unit, .{
        s.read,
        s.generator.effect(),
    }, .{ .use = .reusable, .captures = .{ s.subject_schema, s.generator.capability() } });
    const work_fn = try c.functionFor("read and offer", work_type);
    const work = try start.closureBody(work_fn);
    const result = try work.call(s.loop, .{
        .subject = subject,
        .offset = try work.constant(u64, 0),
        .lines = try work.constant(u64, 0),
    });
    _ = try work.performLocal(s.generator.effect(), capability, result);
    try c.define(work_fn, try work.ret(try work.constant(void, {})));
    const cleanup_type = try c.callable(
        .{ .exit = try c.cleanupInfo(e.unit) },
        e.unit,
        &.{s.close},
        .{ .use = .reusable, .captures = .{s.subject_schema} },
    );
    const cleanup_fn = try c.functionFor("close text subject", cleanup_type);
    const cleanup = try start.closureBody(cleanup_fn);
    try c.define(cleanup_fn, try cleanup.ret(try cleanup.perform(s.close, subject)));
    try c.define(
        start_fn,
        try start.ret(
            try start.protect(
                try start.lambda(work_fn, work_type),
                try start.lambda(cleanup_fn, cleanup_type),
                .{},
            ),
        ),
    );
    try defineAnswer(e, s.generator, .{
        .valid = valid,
        .start_fn = start_fn,
        .start_type = start_type,
        .entry = entry,
        .invalid = invalid,
        .subject = subject,
        .main = main,
    });
    return main;
}

fn encodeComponent(allocator: std.mem.Allocator, e: Emit, s: anytype) ![]u8 {
    const c = e.c;
    var compiled = try source.component.compile(allocator, try c.module(s.main, e.unit), .{
        .imports = &.{ .{ .name = "read", .reference = .{
            .kind = .effect,
            .id = try a.interop.operationId(c, s.read),
        } }, .{ .name = "close", .reference = .{
            .kind = .effect,
            .id = try a.interop.operationId(c, s.close),
        } } },
        .exports = &.{.{ .name = "inspect", .reference = .{
            .kind = .function,
            .id = try a.interop.functionId(c, s.main),
        } }},
    });
    defer compiled.deinit();
    const bytes = try allocator.alloc(u8, try data.component.encodedLength(compiled.object));
    errdefer allocator.free(bytes);
    _ = try compiled.encode(allocator, bytes);
    return bytes;
}

fn defineAnswer(e: Emit, generator: anytype, s: anytype) !void {
    const c = e.c;
    const answer = try s.valid.handleWith(generator.handler(), try s.valid.lambda(
        s.start_fn,
        s.start_type,
    ), .{});
    const done = try s.valid.caseOf(answer, "done");
    const yielded = try s.valid.caseOf(answer, "yielded");
    const parts = try yielded.body().destructure(yielded.payload());
    const returned = try parts.get("value");
    _ = try yielded.body().disposePackage(try parts.get("future"));
    const handled = try s.valid.match(answer, .{
        .done = try done.ret(try e.rejected(done.body(), "invalid_reply")),
        .yielded = try yielded.ret(returned),
    });
    try c.define(
        s.main,
        try s.entry.ret(
            try s.entry.conditional(
                try s.entry.less(
                    try s.entry.constant(u64, maximum_subject_bytes),
                    try s.entry.field(s.subject, "length"),
                ),
                try s.invalid.ret(try e.rejected(s.invalid, "invalid_reply")),
                try s.valid.ret(handled),
            ),
        ),
    );
}
