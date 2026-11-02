const std = @import("std");
const horos = @import("horos");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const t = @import("adaptive_types");
const environment = @import("adaptive_environment");
const example = @import("projection_example");
const recovery = @import("adaptive_recovery.zig");
const cleanup = @import("native_test_support.zig").cleanup;
const wc = contracts.workspace;
const ns = native.testing.state;

pub const Program = struct { program: wc.Ref, input_schema: wc.Ref };
pub const Run = struct { work: wc.Ref, result: wc.Ref };
const CapturedRequest = struct { attempt: ns.Digest, prepared: ns.Reference, body: []const u8 };
pub const Options = struct {
    request_bytes: ?u32 = null,
    begin: bool = true,
    reconstruct: bool = false,
};

pub const Fixture = struct {
    a: std.mem.Allocator,
    io: std.Io,
    arena: std.heap.ArenaAllocator,
    permanent: std.mem.Allocator,
    temporary: std.testing.TmpDir,
    directory: []const u8,
    path: []const u8,
    assets: native.discovery.Assets,
    handlers: native.Registry,
    application: native.discovery.Application,
    profile: native.tasks.Profile,
    namespace: native.Namespace,
    service: native.tasks.Service(t),
    task: ns.TaskId,
    pending: native.tasks.Work,
    prepared: t.P.AdaptivePrepared,
    calls: u64 = 0,
    live: bool = false,

    pub fn init(self: *Fixture) !void {
        try self.initOptions(.{});
    }

    pub fn initOptions(self: *Fixture, options: Options) !void {
        self.a = std.testing.allocator;
        self.io = std.testing.io;
        self.arena = std.heap.ArenaAllocator.init(self.a);
        errdefer self.arena.deinit();
        self.permanent = self.arena.allocator();
        self.temporary = std.testing.tmpDir(.{});
        errdefer self.temporary.cleanup();
        var buffer: [4096]u8 = undefined;
        const length = try self.temporary.dir.realPath(self.io, &buffer);
        self.directory = try self.permanent.dupe(u8, buffer[0..length]);
        self.path = try std.fmt.allocPrint(self.permanent, "{s}/state", .{self.directory});
        self.assets = try recovery.recoveryAssets(self.a, self.permanent);
        self.handlers = try recovery.workspaceRecoveryHandlers(self.a);
        errdefer self.handlers.deinit();
        self.application = try native.discovery.Application.init(
            t,
            self.a,
            self.assets,
            self.handlers,
        );
        errdefer self.application.deinit();
        const configured = try configure(self, options);
        const grants = try self.permanent.alloc(native.registry.Grant, self.handlers.entries.len);
        self.profile = try recovery.recoveryProfile(
            self.a,
            configured,
            self.handlers,
            &self.application,
            grants,
        );
        self.namespace = try native.Namespace.open(self.a, self.io, self.path);
        errdefer cleanup("projection namespace.close", self.namespace.close());
        self.service = try native.tasks.Service(t).init(
            self.a,
            self.io,
            &self.namespace,
            self.assets,
            &self.application,
            self.handlers,
            self.profile,
        );
        errdefer cleanup("projection service.close", self.service.close(self.a));
        self.calls = 0;
        self.live = true;
        self.task = (try self.service.submit(self.permanent, "projection-task", .{ .task = .{
            .bytes = "Examine every distinct member of declared domain 41 revision 7. " ++
                "Distinguish a witnessed mismatch, complete examination, and incomplete " ++
                "coverage. Keep the pending sibling owned until its own completion.",
        } })).receipt.task;
        _ = try self.service.message(self.permanent, "projection-user-1", self.task, .{
            .message = .{ .bytes = "An unavailable member is incomplete, never absent." },
        });
        _ = try self.service.message(self.permanent, "projection-user-2", self.task, .{
            .message = .{ .bytes = "Preserve the original domain " ++
                "throughout representation repair." },
        });
        if (options.begin) try self.next();
    }

    pub fn deinit(self: *Fixture) void {
        if (self.live) {
            if (self.service.work) |work| cleanup(
                "projection pending work",
                self.service.completeWork(self.permanent, work, .not_sent),
            );
            cleanup("projection service.close", self.service.close(self.a));
            cleanup("projection namespace.close", self.namespace.close());
        }
        self.application.deinit();
        self.handlers.deinit();
        self.temporary.cleanup();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn next(self: *Fixture) !void {
        for (0..16384) |_| {
            const step = try self.service.pump(self.permanent);
            if (step != .work) continue;
            if (step.work.entry.declaration.inference) {
                self.pending = step.work;
                const decoded = try contracts.decodeOwned(
                    t.P.AdaptivePrepared,
                    self.permanent,
                    step.work.prepared.?,
                );
                self.prepared = decoded.value;
                return;
            }
            try self.complete(step.work);
        }
        var stopped = try self.service.task(self.permanent, self.task);
        defer stopped.deinit();
        std.debug.print("projection stopped: outcome={s} schedule={s} blocker={any}\n", .{
            @tagName(stopped.value.outcome_kind),
            @tagName(stopped.value.schedule),
            stopped.value.blocker,
        });
        return error.ProjectionInferenceDidNotArrive;
    }

    pub fn complete(self: *Fixture, work: native.tasks.Work) !void {
        if (work.operation == .workspace_build) {
            const worker = try native.testing.Worker.init(self.a, self.io);
            defer cleanup("projection worker.deinit", worker.deinit(self.a));
            try worker.start(work, self.profile.authority, null);
            while (!worker.finished()) try self.io.sleep(.fromMilliseconds(1), .awake);
            try worker.join();
            defer cleanup("projection worker.release", worker.release());
            try std.testing.expect(worker.result.? == .acquired);
            try self.service.completeWork(self.permanent, work, worker.result.?);
            return;
        }
        const protocol = horos.data.invocation;
        var invocation = try protocol.decode(protocol.Request, self.permanent, work.request);
        defer invocation.deinit();
        const ctx: native.Context = .{
            .allocator = self.permanent,
            .io = self.io,
            .authority = &self.profile.authority,
            .task_id = &std.fmt.bytesToHex(self.task, .lower),
            .profile = self.profile.bytes,
            .environment = self.profile.environment,
        };
        const reply = if (work.entry.declaration.capture) |adapter| blk: {
            const acquired = try adapter.acquire(ctx, work.prepared.?);
            try std.testing.expect(acquired == .captured);
            break :blk acquired.captured;
        } else try work.entry.declaration.invoke.?(ctx, invocation.value.binding.payload);
        try self.service.acquire(self.permanent, work, reply);
    }

    pub fn send(self: *Fixture, action: t.Action) !void {
        const encoded = try recovery.modelArguments(t.Action, self.permanent, action);
        const arguments = try native.json.canonical(
            self.permanent,
            encoded.object.get("value").?,
        );
        const body = try std.json.Stringify.valueAlloc(self.permanent, .{
            .status = "completed",
            .@"error" = @as(?u8, null),
            .usage = .{ .input_tokens = 7, .output_tokens = 3, .total_tokens = 10 },
            .output = .{.{
                .type = "function_call",
                .status = "completed",
                .call_id = try std.fmt.allocPrint(self.permanent, "projection-{d}", .{self.calls}),
                .name = @tagName(action),
                .arguments = arguments,
            }},
        }, .{});
        const raw = try contracts.encodeOwned(native.responses.Raw, self.permanent, .{
            .status = 200,
            .identity_encoding = true,
            .request_id = null,
            .body = .{ .bytes = body },
        });
        self.calls += 1;
        try self.service.acquire(self.permanent, self.pending, raw);
    }

    pub fn attempt(self: *Fixture, action: t.Action) !native.json.Value {
        try self.send(action);
        try self.next();
        try std.testing.expectEqual(@as(usize, 1), self.prepared.request.results.items.len);
        const output = self.prepared.request.results.items[0].output.bytes;
        return (try native.json.parse(self.permanent, output, .{})).value;
    }

    pub fn perform(self: *Fixture, action: t.Action) !native.json.Value {
        const reply = try self.attempt(action);
        const disposition = reply.object.get("disposition") orelse return error.MissingDisposition;
        if (std.mem.eql(u8, disposition.string, "rejected")) {
            std.debug.print("projection action rejected: {s}\n", .{
                try native.json.canonical(self.permanent, reply),
            });
            return error.ProjectionActionRejected;
        }
        return reply.object.get("observation") orelse return error.MissingObservation;
    }

    pub fn buildSource(
        self: *Fixture,
        source: []const u8,
        exposures: []const wc.Exposure,
    ) !Program {
        const observed = try self.perform(.{ .program = .{ .command = .{ .build = .{
            .source = .{ .json_text = .{ .bytes = source } },
            .source_kind = .source_records,
            .exposures = .{ .items = exposures },
        } } } });
        return .{
            .program = try self.ref(observed, "program"),
            .input_schema = try self.ref(observed, "input_schema"),
        };
    }

    pub fn consumer(self: *Fixture) !wc.Ref {
        return self.ref(try self.perform(.{ .context = .{ .command = .{ .inspect = .{
            .page = .{},
            .consumer = .{ .target = .{ .controller = .{} } },
        } } } }), "consumer");
    }

    pub fn json(self: *Fixture, comptime T: type, payload: T) !native.json.Value {
        const schema = try native.values.schemaBytes(T, self.permanent);
        const bytes = try contracts.encodeOwned(T, self.permanent, payload);
        const decoded = try native.dynamic_values.decode(self.permanent, schema, bytes);
        return decoded.value;
    }

    pub fn materialize(
        self: *Fixture,
        schema: wc.Ref,
        wanted: native.json.Value,
        sources: []const wc.Ref,
    ) !wc.Ref {
        const observed = try self.perform(.{ .context = .{ .command = .{ .materialize = .{
            .input = .{ .value = .{ .inline_json = .{
                .schema = schema,
                .json_text = .{ .bytes = try native.json.canonical(self.permanent, wanted) },
            } } },
            .sources = .{ .items = sources },
        } } } });
        return self.ref(observed, "value");
    }

    pub fn run(self: *Fixture, program: wc.Ref, input: wc.Ref) !Run {
        var observed = try self.perform(.{ .work = .{ .command = .{ .start = .{
            .program = program,
            .input = .{ .reference = input },
            .policy = .{ .stop = .terminal, .continuation = .owner_scheduled },
        } } } });
        const work = try self.ref(observed, "work");
        for (0..128) |_| {
            const outcome = observed.object.get("outcome").?.string;
            if (std.mem.eql(u8, outcome, "completed")) return .{
                .work = work,
                .result = try self.ref(observed, "result"),
            };
            try std.testing.expect(!std.mem.eql(u8, outcome, "failed"));
            observed = try self.perform(.{ .work = .{ .command = .{ .inspect = .{
                .work = work,
            } } } });
        }
        return error.ProjectionWorkDidNotComplete;
    }

    pub fn ref(self: *Fixture, object: native.json.Value, field: []const u8) !wc.Ref {
        return native.values.fromJson(
            wc.Ref,
            self.permanent,
            object.object.get(field) orelse return error.MissingReference,
        );
    }

    pub fn value(self: *Fixture, reference: wc.Ref) !native.workspace.Value {
        const digest = try refId(reference);
        const id = try native.workspace.custodyId(self.permanent, self.task, digest);
        const bytes = (try self.namespace.store.recordBytes(
            self.permanent,
            "workspace_value",
            id,
            self.task,
        )) orelse return error.MissingValue;
        const decoded = try contracts.decodeOwned(native.workspace.Value, self.permanent, bytes);
        return decoded.value;
    }

    pub fn decode(self: *Fixture, comptime T: type, reference: wc.Ref) !T {
        const saved = try self.value(reference);
        const wanted = try native.values.schemaBytes(T, self.permanent);
        const schema = try self.namespace.store.object(
            self.permanent,
            saved.description.schema,
            null,
        );
        try std.testing.expectEqualSlices(u8, wanted, schema);
        const bytes = try self.namespace.store.object(
            self.permanent,
            saved.description.value,
            null,
        );
        const decoded = try contracts.decodeOwned(T, self.permanent, bytes);
        return decoded.value;
    }

    fn request(self: *Fixture) !CapturedRequest {
        return .{
            .attempt = self.pending.attempt,
            .prepared = digestReference(self.pending.prepared.?),
            .body = try self.permanent.dupe(u8, self.prepared.body.bytes),
        };
    }
};

pub fn refId(reference: wc.Ref) !ns.Digest {
    var id: ns.Digest = undefined;
    _ = try std.fmt.hexToBytes(&id, reference.id.bytes);
    return id;
}

fn digestReference(bytes: []const u8) ns.Reference {
    var digest: ns.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .digest = digest, .bytes = bytes.len };
}

fn configure(f: *Fixture, options: Options) !native.configuration.Admitted {
    const a = f.permanent;
    const base = try environment.configure(a, f.io, .{ .offline = true }, null, f.assets);
    const policy = try native.adaptive_responses.Admission(t.P).policy(a, base.bytes);
    const profiles = try a.dupe(@TypeOf(policy.profiles.items[0]), policy.profiles.items);
    if (options.request_bytes) |maximum| for (profiles) |*profile| {
        profile.request_bytes = maximum;
    };
    try f.temporary.dir.createDir(f.io, "snapshot", .default_dir);
    for (source_files) |file| try f.temporary.dir.writeFile(f.io, .{
        .sub_path = try std.fmt.allocPrint(a, "snapshot/{s}", .{file.path}),
        .data = file.bytes,
    });
    const config: t.ConfigurationV3 = .{
        .schema = .{ .bytes = "adaptive-agent.configuration.v3" },
        .adaptive = .{
            .workspace = .{ .bytes = "projection-repair" },
            .snapshot_root = .{ .bytes = try std.fmt.allocPrint(
                a,
                "{s}/snapshot",
                .{f.directory},
            ) },
            .endpoint = .{ .bytes = "https://127.0.0.1:1/v1/responses" },
            .audience = .{ .bytes = "projection-repair" },
            .profiles = .{ .items = profiles },
            .initial_profile = .{ .bytes = "analysis" },
            .initial_effort = .medium,
            .skills = .{ .items = &.{} },
        },
        .tools = .{
            .build = true,
            .run = true,
            .reconstruct = options.reconstruct,
            .inputs = .{ .items = &.{} },
        },
    };
    const config_path = try std.fmt.allocPrint(a, "{s}/config.json", .{f.directory});
    const json_config = try native.values.toJson(t.ConfigurationV3, a, config);
    try f.temporary.dir.writeFile(f.io, .{
        .sub_path = "config.json",
        .data = try native.json.canonical(a, json_config),
    });
    try f.temporary.dir.writeFile(f.io, .{ .sub_path = "trust", .data = "unused transport" });
    return environment.configure(a, f.io, .{
        .offline = false,
        .test_provider = true,
        .config_path = config_path,
        .trust_root_path = try std.fmt.allocPrint(a, "{s}/trust", .{f.directory}),
    }, null, f.assets);
}

const source_files = [_]struct { path: []const u8, bytes: []const u8 }{
    .{ .path = "domain.json", .bytes = "{\"identity\":41,\"revision\":7,\"members\":[1,2]}" },
    .{ .path = "member-1", .bytes = "1" },
    .{ .path = "member-2", .bytes = "2" },
    .{ .path = "member-2-mismatch", .bytes = "9" },
    .{ .path = "other-domain.json", .bytes = "{\"identity\":42,\"revision\":7,\"members\":[1,2]}" },
    .{ .path = "empty-domain.json", .bytes = "{\"identity\":43,\"revision\":7,\"members\":[]}" },
    .{
        .path = "revised-domain.json",
        .bytes = "{\"identity\":41,\"revision\":8,\"members\":[1,2]}",
    },
};

const Expected = enum { counterexample, exhausted_declared_domain, incomplete };
const Case = struct {
    domain: ?wc.Ref,
    evidence: example.ScanEvidence,
    sources: []const wc.Ref,
};
const Produced = struct { source: Case, run: Run };
const BadPair = struct {
    complete: Produced,
    partial: Produced,
    left: Run,
    right: Run,
    left_request: CapturedRequest,
    right_request: CapturedRequest,
    diagnostic: Run,
};

fn acquire(f: *Fixture, path: []const u8) !wc.Ref {
    return f.ref(try f.perform(.{ .context = .{ .command = .{ .materialize = .{
        .input = .{ .snapshot = .{
            .path = .{ .bytes = path },
            .offset = 0,
            .maximum = 4096,
        } },
        .sources = .{ .items = &.{} },
    } } } }), "value");
}

fn domain(f: *Fixture, reference: wc.Ref) !example.Domain {
    const text = try f.decode(contracts.Utf8, reference);
    const parsed = (try native.json.parse(f.permanent, text.bytes, .{})).value;
    const members = parsed.object.get("members").?.array.items;
    const ids = try f.permanent.alloc(u64, members.len);
    for (members, ids) |member, *id| id.* = try jsonNumber(member);
    return .{
        .identity = try jsonNumber(parsed.object.get("identity").?),
        .revision = try jsonNumber(parsed.object.get("revision").?),
        .known = true,
        .members = .{ .items = ids },
    };
}

fn jsonNumber(value: native.json.Value) !u64 {
    return native.json.numberInteger(u64, value.number_string);
}

fn visit(f: *Fixture, source: wc.Ref, member: u64) !example.Visit {
    const text = try f.decode(contracts.Utf8, source);
    return .{
        .domain_identity = 41,
        .domain_revision = 7,
        .member = member,
        .available = true,
        .observed = try std.fmt.parseInt(u64, text.bytes, 10),
        .evidence = source,
    };
}

fn assess(f: *Fixture, specimen: Case) !Expected {
    const declared = if (specimen.domain) |ref| try domain(f, ref) else return .incomplete;
    const covered = try f.permanent.alloc(bool, declared.members.items.len);
    @memset(covered, false);
    var invalid = false;
    for (specimen.evidence.visits.items) |observed| {
        if (!observed.available) continue;
        const bytes = (try f.decode(contracts.Utf8, observed.evidence)).bytes;
        const actual = try std.fmt.parseInt(u64, bytes, 10);
        const index = std.mem.indexOfScalar(u64, declared.members.items, observed.member);
        if (observed.domain_identity != declared.identity or
            observed.domain_revision != declared.revision or index == null)
        {
            invalid = true;
            continue;
        }
        if (actual != observed.member) return .counterexample;
        covered[index.?] = true;
    }
    if (invalid or std.mem.indexOfScalar(bool, covered, false) != null) return .incomplete;
    return .exhausted_declared_domain;
}

fn produce(f: *Fixture, program: Program, specimen: Case) !Produced {
    const input = try f.materialize(
        program.input_schema,
        try f.json(example.ScanEvidence, specimen.evidence),
        specimen.sources,
    );
    return .{ .source = specimen, .run = try f.run(program.program, input) };
}

fn project(f: *Fixture, program: Program, consumer: wc.Ref, produced: Produced) !Run {
    const observed = try f.decode(example.ScanEvidence, produced.run.result);
    const encoded = try f.json(wc.ProjectionInput(example.ScanEvidence), .{
        .consumer = consumer,
        .value = observed,
    });
    const input = try f.materialize(program.input_schema, encoded, &.{produced.run.result});
    return f.run(program.program, input);
}

fn build(f: *Fixture, program: example.Program) !Program {
    return f.buildSource(try example.source(f.permanent, program), &.{});
}

fn captureProjection(comptime T: type, f: *Fixture, run: Run) !CapturedRequest {
    _ = try f.perform(.{ .context = .{ .command = .{ .select = .{
        .projected = run.result,
    } } } });
    try std.testing.expect(f.prepared.selected_view != null);
    try requirePayload(T, f, run.result, f.prepared.body.bytes);
    return f.request();
}

fn requirePayload(comptime T: type, f: *Fixture, result: wc.Ref, body: []const u8) !void {
    const block = try computedBlock(f.permanent, body);
    try std.testing.expectEqualDeep(result, try f.ref(block, "result"));
    const schema = try native.values.schemaBytes(T, f.permanent);
    const schema_id = digestReference(schema).digest;
    try std.testing.expectEqualStrings(
        &std.fmt.bytesToHex(schema_id, .lower),
        block.object.get("schema_identity").?.string,
    );
    const actual = try native.dynamic_values.encode(
        f.permanent,
        schema,
        block.object.get("value").?,
    );
    const expected = try f.decode(wc.ProjectionResult(T), result);
    const expected_bytes = try contracts.encodeOwned(T, f.permanent, expected.value);
    try std.testing.expectEqualSlices(u8, expected_bytes, actual);
}

fn compare(
    f: *Fixture,
    program: Program,
    left: Produced,
    right: Produced,
    left_projection: Run,
    right_projection: Run,
) !Run {
    const input = try f.materialize(program.input_schema, try f.json(example.ComparisonInput, .{
        .left = try f.decode(wc.ProjectionResult(example.BadOutcome), left_projection.result),
        .right = try f.decode(wc.ProjectionResult(example.BadOutcome), right_projection.result),
        .left_evidence = try f.decode(example.ScanEvidence, left.run.result),
        .right_evidence = try f.decode(example.ScanEvidence, right.run.result),
    }), &.{ left_projection.result, right_projection.result, left.run.result, right.run.result });
    const run = try f.run(program.program, input);
    const result = try f.decode(example.Comparison, run.result);
    try std.testing.expect(result.equal_projected_payload and result.distinct_required_outcomes);
    try std.testing.expect(result.left == .exhausted_declared_domain);
    try std.testing.expect(result.right == .incomplete);
    const observation = try f.perform(.{ .context = .{ .command = .{ .expand = .{
        .reference = run.result,
        .page = .{},
    } } } });
    try std.testing.expect(observation.object.get("complete").?.bool);
    const inspected = try native.json.parse(
        f.permanent,
        observation.object.get("text").?.string,
        .{},
    );
    const schema = try native.values.schemaBytes(example.Comparison, f.permanent);
    const actual = try native.dynamic_values.encode(f.permanent, schema, inspected.value);
    const expected = try contracts.encodeOwned(example.Comparison, f.permanent, result);
    try std.testing.expectEqualSlices(u8, expected, actual);
    return run;
}

fn badPair(f: *Fixture, producer: Program) !BadPair {
    const declaration = try acquire(f, "domain.json");
    const first = try acquire(f, "member-1");
    const second = try acquire(f, "member-2");
    const examined = try f.permanent.alloc(example.Visit, 2);
    examined[0] = try visit(f, first, 1);
    examined[1] = try visit(f, second, 2);
    const complete: Case = .{
        .domain = declaration,
        .evidence = .{ .domain = try domain(f, declaration), .visits = .{ .items = examined } },
        .sources = try f.permanent.dupe(wc.Ref, &.{ declaration, first, second }),
    };
    var partial = complete;
    partial.evidence.visits.items = examined[0..1];
    partial.sources = try f.permanent.dupe(wc.Ref, &.{ declaration, first });
    try std.testing.expectEqual(.exhausted_declared_domain, try assess(f, complete));
    try std.testing.expectEqual(.incomplete, try assess(f, partial));
    const left = try produce(f, producer, complete);
    const right = try produce(f, producer, partial);
    const bad = try build(f, .bad_projector);
    const consumer = try f.consumer();
    const left_projection = try project(f, bad, consumer, left);
    const right_projection = try project(f, bad, consumer, right);
    const l = try f.decode(wc.ProjectionResult(example.BadOutcome), left_projection.result);
    const r = try f.decode(wc.ProjectionResult(example.BadOutcome), right_projection.result);
    try std.testing.expectEqualDeep(l.value, r.value);
    try std.testing.expect(l.value.no_counterexample_observed);
    const left_request = try captureProjection(example.BadOutcome, f, left_projection);
    const right_request = try captureProjection(example.BadOutcome, f, right_projection);
    try std.testing.expect(!std.meta.eql(left_request.attempt, right_request.attempt));
    return .{
        .complete = left,
        .partial = right,
        .left = left_projection,
        .right = right_projection,
        .left_request = left_request,
        .right_request = right_request,
        .diagnostic = try compare(
            f,
            try build(f, .comparison),
            left,
            right,
            left_projection,
            right_projection,
        ),
    };
}

fn checkRepaired(f: *Fixture, program: Program, consumer: wc.Ref, produced: Produced) !Run {
    const run = try project(f, program, consumer, produced);
    try requireRepaired(f, produced.source, run);
    return run;
}

fn checkVariant(f: *Fixture, program: Program, consumer: wc.Ref, specimen: Case) !void {
    const encoded = try f.json(wc.ProjectionInput(example.ScanEvidence), .{
        .consumer = consumer,
        .value = specimen.evidence,
    });
    const input = try f.materialize(program.input_schema, encoded, specimen.sources);
    try requireRepaired(f, specimen, try f.run(program.program, input));
}

fn requireRepaired(f: *Fixture, specimen: Case, run: Run) !void {
    const result = try f.decode(wc.ProjectionResult(example.ScanOutcome), run.result);
    const expected = try assess(f, specimen);
    try std.testing.expectEqualStrings(@tagName(expected), @tagName(result.value));
    if (result.value == .counterexample) {
        const witness = result.value.counterexample;
        const acquired = try f.decode(contracts.Utf8, witness.evidence);
        try std.testing.expectEqual(
            witness.observed,
            try std.fmt.parseInt(u64, acquired.bytes, 10),
        );
        try std.testing.expect(witness.observed != witness.member);
    }
}

fn variants(f: *Fixture, original: Case) ![]const Case {
    const cases = try f.permanent.alloc(Case, 8);
    @memset(cases, original);
    const complete = original.evidence.visits.items;
    cases[0].evidence.visits.items = try f.permanent.dupe(
        example.Visit,
        &.{ complete[0], complete[0] },
    );
    cases[1].evidence.visits.items = try f.permanent.dupe(
        example.Visit,
        &.{ complete[1], complete[0], complete[1] },
    );
    const mismatch = try acquire(f, "member-2-mismatch");
    cases[2].evidence.visits.items = try f.permanent.dupe(
        example.Visit,
        &.{ complete[0], try visit(f, mismatch, 2) },
    );
    cases[2].sources = try f.permanent.dupe(
        wc.Ref,
        &.{ original.domain.?, mismatch, complete[0].evidence },
    );
    cases[3].domain = try acquire(f, "revised-domain.json");
    cases[3].evidence.domain = try domain(f, cases[3].domain.?);
    cases[3].sources = try f.permanent.dupe(
        wc.Ref,
        &.{ cases[3].domain.?, complete[0].evidence, complete[1].evidence },
    );
    cases[4].domain = try acquire(f, "other-domain.json");
    cases[4].evidence.domain = try domain(f, cases[4].domain.?);
    cases[4].sources = try f.permanent.dupe(
        wc.Ref,
        &.{ cases[4].domain.?, complete[0].evidence, complete[1].evidence },
    );
    cases[5].domain = null;
    cases[5].evidence.domain.known = false;
    cases[6].domain = try acquire(f, "empty-domain.json");
    cases[6].evidence.domain = try domain(f, cases[6].domain.?);
    cases[6].evidence.visits.items = &.{};
    cases[6].sources = try f.permanent.dupe(wc.Ref, &.{cases[6].domain.?});
    const unavailable = try f.attempt(.{ .context = .{ .command = .{ .materialize = .{
        .input = .{ .snapshot = .{
            .path = .{ .bytes = "unavailable-member-2" },
            .offset = 0,
            .maximum = 4096,
        } },
        .sources = .{ .items = &.{} },
    } } } });
    try std.testing.expectEqualStrings("rejected", unavailable.object.get("disposition").?.string);
    try std.testing.expectEqualStrings(
        "SourceMissing",
        unavailable.object.get("observation").?.object.get("error").?.string,
    );
    var failed = complete[1];
    failed.available = !std.mem.eql(u8, unavailable.object.get("disposition").?.string, "rejected");
    cases[7].evidence.visits.items = try f.permanent.dupe(
        example.Visit,
        &.{ complete[0], failed },
    );
    return cases;
}

fn sibling(f: *Fixture) !native.workspace.Work {
    var builder = horos.source.Builder.init(f.permanent);
    defer builder.deinit();
    const module = try @import("workspace_sources.zig").binaryQuestion(&builder);
    const program = try f.buildSource(
        try native.source_records.encode(f.permanent, module),
        &.{.{ .effect = 0, .class = .input }},
    );
    const observed = try f.perform(.{ .work = .{ .command = .{ .start = .{
        .program = program.program,
        .input = .{ .inline_json = .{
            .schema = program.input_schema,
            .json_text = .{ .bytes = "{}" },
        } },
        .policy = .{ .stop = .next_exposed_event, .continuation = .owner_scheduled },
    } } } });
    const ref = try f.ref(observed, "work");
    for (0..128) |_| {
        const saved = try f.service.workspaceWork(f.permanent, f.task, try refId(ref));
        if (saved.value.current_port != null) return saved.value;
        _ = try f.perform(.{ .work = .{ .command = .{ .inspect = .{ .work = ref } } } });
    }
    return error.PendingSiblingDidNotArrive;
}

fn requireSibling(f: *Fixture, original: native.workspace.Work) !void {
    const current = try f.service.workspaceWork(f.permanent, f.task, original.id);
    try std.testing.expectEqual(original.task, current.value.task);
    try std.testing.expectEqual(original.execution_revision, current.value.execution_revision);
    try std.testing.expectEqual(original.control_revision, current.value.control_revision);
    try std.testing.expectEqualDeep(original.current_port, current.value.current_port);
    try std.testing.expectEqual(original.port_generation, current.value.port_generation);
    try std.testing.expect(current.value.result == null);
    try std.testing.expect(current.value.cancellation == null);
}

fn completeSibling(f: *Fixture, original: native.workspace.Work) !void {
    const reference = @import("workspace_test_support.zig").workspaceRef;
    const work = try reference(f.permanent, .work, original.id);
    const saved_port = original.current_port.?;
    const port = try contracts.decodeOwned(
        native.workspace.Port,
        f.permanent,
        try f.namespace.store.object(f.permanent, saved_port, null),
    );
    _ = try f.perform(.{ .work = .{ .command = .{ .interact = .{
        .expected = .{
            .work = work,
            .execution_revision = original.execution_revision,
            .control_revision = original.control_revision,
        },
        .port = try reference(f.permanent, .port, port.value.id),
        .generation = original.port_generation,
        .command = .{ .resume_value = .{ .inline_json = .{
            .schema = try reference(f.permanent, .schema, port.value.interface.argument.digest),
            .json_text = .{ .bytes = "true" },
        } } },
    } } } });
    for (0..128) |_| {
        const current = try f.service.workspaceWork(f.permanent, f.task, original.id);
        if (current.value.outcome_kind == .completed) {
            const result = try reference(f.permanent, .value, current.value.result_value.?.digest);
            try std.testing.expect(try f.decode(bool, result));
            return;
        }
        _ = try f.perform(.{ .work = .{ .command = .{ .inspect = .{ .work = work } } } });
    }
    return error.SiblingCompletionDidNotArrive;
}

fn selectedView(f: *Fixture, result: wc.Ref) !?native.workspace.View {
    var rows = try f.namespace.store.database.prepare(
        "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body " ++
            "WHERE r.kind='workspace_view' AND r.task=?",
        &.{.{ .blob = &f.task }},
    );
    defer rows.deinit();
    const wanted = try refId(result);
    while (try rows.step() == .row) {
        const view = try contracts.decodeOwned(
            native.workspace.View,
            f.permanent,
            try rows.bytes(0),
        );
        if (view.value.description.projection) |projection|
            if (std.meta.eql(projection.result.digest, wanted)) return view.value;
    }
    return null;
}

fn commitSelection(f: *Fixture, result: wc.Ref) !native.workspace.View {
    const before = (try f.service.task(f.permanent, f.task)).value.inference_attempts;
    try std.testing.expect((try selectedView(f, result)) == null);
    try f.send(.{ .context = .{ .command = .{ .select = .{ .projected = result } } } });
    for (0..16384) |_| {
        const step = try f.service.pump(f.permanent);
        if (step == .work) {
            try std.testing.expect(!step.work.entry.declaration.inference);
            try f.complete(step.work);
        }
        const current = (try f.service.task(f.permanent, f.task)).value;
        try std.testing.expectEqual(before, current.inference_attempts);
        if (try selectedView(f, result)) |view| return view;
    }
    return error.ProjectionSelectionWasNotCommitted;
}

fn reopen(f: *Fixture) !void {
    try f.service.close(f.permanent);
    try f.namespace.close();
    f.live = false;
    f.namespace = try native.Namespace.open(f.a, f.io, f.path);
    errdefer cleanup("reopened namespace.close", f.namespace.close());
    f.service = try native.tasks.Service(t).init(
        f.a,
        f.io,
        &f.namespace,
        f.assets,
        &f.application,
        f.handlers,
        f.profile,
    );
    f.live = true;
    const current = try f.service.task(f.permanent, f.task);
    _ = try f.service.resumeTask(
        f.permanent,
        "projection-repair-resume",
        f.task,
        current.value.revision,
    );
}

fn inspectRequest(f: *Fixture, captured: CapturedRequest) !void {
    const bytes = (try f.namespace.store.recordBytes(
        f.permanent,
        "attempt",
        captured.attempt,
        f.task,
    )) orelse return error.MissingOriginalRequest;
    const attempt = try contracts.decodeOwned(ns.Attempt, f.permanent, bytes);
    try std.testing.expectEqualDeep(captured.prepared, attempt.value.prepared.?);
    const prepared = try contracts.decodeOwned(
        t.P.AdaptivePrepared,
        f.permanent,
        try f.namespace.store.object(f.permanent, captured.prepared, null),
    );
    try std.testing.expectEqualSlices(u8, captured.body, prepared.value.body.bytes);
}

fn preserveHistory(
    f: *Fixture,
    before: ns.Task,
    original: BadPair,
    pending: native.workspace.Work,
    repaired: CapturedRequest,
) !void {
    const after = (try f.service.task(f.permanent, f.task)).value;
    try std.testing.expectEqual(before.id, after.id);
    try std.testing.expectEqualDeep(before.input, after.input);
    try std.testing.expectEqualDeep(before.messages, after.messages);
    try std.testing.expectEqual(before.next_message, after.next_message);
    try std.testing.expect(after.inference_attempts > before.inference_attempts);
    try std.testing.expect(after.inference_request_bytes > before.inference_request_bytes);
    try std.testing.expect(after.inference_output_tokens > before.inference_output_tokens);
    try std.testing.expect(!std.meta.eql(repaired.attempt, original.left_request.attempt));
    try inspectRequest(f, original.left_request);
    try inspectRequest(f, original.right_request);
    try inspectRequest(f, repaired);
    try requireSibling(f, pending);
    const comparison = try f.decode(example.Comparison, original.diagnostic.result);
    try std.testing.expect(
        comparison.equal_projected_payload and comparison.distinct_required_outcomes,
    );
    const saved = try f.value(original.diagnostic.result);
    try std.testing.expectEqual(.computation, saved.derivation.kind);
    const work = try f.service.workspaceWork(
        f.permanent,
        f.task,
        try refId(original.diagnostic.work),
    );
    try std.testing.expectEqualDeep(saved.artifact, work.value.result_value.?);
    try std.testing.expect(work.value.input_value != null);
    _ = try f.service.workspaceProgram(f.permanent, f.task, work.value.program);
    try retainedMessages(f);
    try requireAncestor(f, original.diagnostic.result, original.left.result);
    try requireAncestor(f, original.diagnostic.result, original.right.result);
    try requireAncestor(f, original.diagnostic.result, original.complete.source.domain.?);
}

fn retainedMessages(f: *Fixture) !void {
    var rows = try f.namespace.store.database.prepare(
        "SELECT o.body FROM records r JOIN objects o ON o.digest=r.body " ++
            "WHERE r.kind='message' AND r.task=?",
        &.{.{ .blob = &f.task }},
    );
    defer rows.deinit();
    const expected = [_][]const u8{
        "An unavailable member is incomplete, never absent.",
        "Preserve the original domain throughout representation repair.",
    };
    var seen = [_]bool{ false, false };
    while (try rows.step() == .row) {
        const message = try contracts.decodeOwned(ns.Message, f.permanent, try rows.bytes(0));
        try std.testing.expect(message.value.ordinal > 0 and
            message.value.ordinal <= expected.len);
        const index: usize = @intCast(message.value.ordinal - 1);
        try std.testing.expect(!seen[index]);
        seen[index] = true;
        const input = try contracts.decodeOwned(
            t.Message,
            f.permanent,
            try f.namespace.store.object(f.permanent, message.value.value, null),
        );
        try std.testing.expectEqualStrings(expected[index], input.value.message.bytes);
        try std.testing.expectEqual(.consumed, message.value.disposition);
    }
    try std.testing.expect(seen[0] and seen[1]);
}

fn requireAncestor(f: *Fixture, result: wc.Ref, ancestor: wc.Ref) !void {
    var pending: std.ArrayList(wc.Ref) = .empty;
    defer pending.deinit(f.permanent);
    var seen: std.AutoHashMap(ns.Digest, void) = .init(f.permanent);
    defer seen.deinit();
    try pending.append(f.permanent, result);
    const wanted = try refId(ancestor);
    while (pending.pop()) |next_ref| {
        const id = try refId(next_ref);
        if (std.meta.eql(id, wanted)) return;
        const visited = try seen.getOrPut(id);
        if (visited.found_existing) continue;
        const value = try f.value(next_ref);
        for (value.derivation.sources.items) |ref| try pending.append(f.permanent, .{
            .kind = .value,
            .id = .{ .bytes = try f.permanent.dupe(u8, &std.fmt.bytesToHex(ref.digest, .lower)) },
        });
    }
    return error.RequiredProjectionAncestorMissing;
}

test "ordinary projection repair preserves lost coverage distinction through first-use restart" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const pending = try sibling(&f);
    const producer = try build(&f, .producer);
    const original = try badPair(&f, producer);
    try requireSibling(&f, pending);
    const repaired = try build(&f, .repaired_projector);
    const consumer = try f.consumer();
    const complete = try checkRepaired(&f, repaired, consumer, original.complete);
    const partial = try checkRepaired(&f, repaired, consumer, original.partial);
    const bad_value = try f.value(original.left.result);
    const repaired_value = try f.value(complete.result);
    try std.testing.expect(!std.meta.eql(
        bad_value.description.schema,
        repaired_value.description.schema,
    ));
    for (try variants(&f, original.complete.source)) |specimen| {
        try checkVariant(&f, repaired, consumer, specimen);
        try requireSibling(&f, pending);
    }
    const selected = try commitSelection(&f, partial.result);
    const before = (try f.service.task(f.permanent, f.task)).value;
    try reopen(&f);
    try f.next();
    try std.testing.expectEqualDeep(selected.artifact.digest, f.prepared.selected_view.?.digest);
    try std.testing.expectEqual(selected.artifact.bytes, f.prepared.selected_view.?.bytes);
    try requirePayload(example.ScanOutcome, &f, partial.result, f.prepared.body.bytes);
    const first_repaired = try f.request();
    _ = try f.perform(.{ .context = .{ .command = .{ .expand = .{
        .reference = original.diagnostic.result,
        .page = .{},
    } } } });
    try preserveHistory(&f, before, original, pending, first_repaired);
    _ = try captureProjection(example.ScanOutcome, &f, complete);
    try requireSibling(&f, pending);
    try completeSibling(&f, pending);
}

pub fn computedBlock(a: std.mem.Allocator, body: []const u8) !native.json.Value {
    const request = try native.json.parseAsset(a, body, body.len);
    for (request.value.object.get("input").?.array.items) |item| {
        const content = item.object.get("content") orelse continue;
        if (content == .string) {
            if (try computedText(a, content.string)) |block| return block;
            continue;
        }
        if (content != .array) continue;
        for (content.array.items) |part| {
            const text = part.object.get("text") orelse continue;
            if (text != .string) continue;
            if (try computedText(a, text.string)) |block| return block;
        }
    }
    return error.ComputedProjectionMissingFromRequest;
}

fn computedText(a: std.mem.Allocator, text: []const u8) !?native.json.Value {
    if (!std.mem.startsWith(u8, text, "{") or
        std.mem.indexOf(u8, text, "\"selected_context_data\"") == null) return null;
    const rendered = try native.json.parseAsset(a, text, text.len);
    const input = rendered.value.object.get("inputs") orelse rendered.value;
    const blocks = input.object.get("selected_context_data") orelse return null;
    for (blocks.array.items) |block| {
        const kind = block.object.get("kind") orelse continue;
        if (std.mem.eql(u8, kind.string, "computed")) return block;
    }
    return null;
}
