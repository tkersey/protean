const std = @import("std");
const native = @import("protean_native");
const contracts = @import("protean_contracts");
const types = @import("application_types");
const sources = @import("interface_repair_sources");
const fixture = @import("recurrence_fixture.zig");
const wc = contracts.workspace;
const Json = native.json;
const Service = native.tasks.Service(types);
const Allocator = std.mem.Allocator;

const Author = struct {
    service: *Service,
    worker: *native.testing.Worker,
    arena: Allocator,
    pending: native.tasks.Work,

    fn perform(
        self: *Author,
        comptime name: []const u8,
        cmd: @FieldType(wc.Command, name),
    ) !Json.Value {
        const a = self.arena;
        if (comptime std.mem.eql(u8, name, "context"))
            return fixture.context(self.service, self.worker, a, &self.pending, cmd);
        const Payload = @FieldType(types.Action, name);
        const args = try native.values.toJson(Payload, a, .{ .command = cmd });
        return fixture.action(self.service, self.worker, a, &self.pending, name, args);
    }

    fn complete(self: *Author, program: wc.Ref, input: wc.Ref) !Json.Value {
        var observed = try self.perform("work", .{ .start = .{
            .program = program,
            .input = .{ .reference = input },
            .policy = .{ .stop = .terminal, .continuation = .owner_scheduled },
        } });
        const work = try fixture.reference(self.arena, observed, "work");
        for (0..128) |_| {
            const outcome = try Json.text(Json.get(observed, "outcome") orelse
                return error.MissingWorkOutcome);
            if (std.mem.eql(u8, outcome, "completed")) return observed;
            if (std.mem.eql(u8, outcome, "failed")) return error.ProjectionWorkFailed;
            observed = try self.perform("work", .{ .inspect = .{ .work = work } });
        }
        return error.ProjectionWorkIncomplete;
    }
};

fn canonicalEvidence(
    service: *Service,
    a: Allocator,
    task: [16]u8,
    input: wc.Ref,
) !sources.ScanEvidence {
    if (input.kind != .value) return error.InvalidCanonicalInput;
    const store = &service.namespace.store;
    const digest = try native.client.identifier(32, Json.string(input.id.bytes));
    const key = try native.workspace.custodyId(a, task, digest);
    const record = (try store.recordBytes(a, "workspace_value", key, task)) orelse
        return error.MissingCanonicalInput;
    const value = (try contracts.decodeOwned(native.workspace.Value, a, record)).value;
    const Input = wc.ProjectionInput(sources.ScanEvidence);
    const schema = try store.object(a, value.description.schema, null);
    if (!std.mem.eql(u8, schema, try native.values.schemaBytes(Input, a)))
        return error.InvalidCanonicalInput;
    const bytes = try store.object(a, value.description.value, null);
    return (try contracts.decodeOwned(Input, a, bytes)).value.value;
}

pub fn run(
    service: *Service,
    worker: *native.testing.Worker,
    a: Allocator,
    task: [16]u8,
    canonical_input: wc.Ref,
) !Json.Value {
    const evidence = try canonicalEvidence(service, a, task, canonical_input);
    var author: Author = .{
        .service = service,
        .worker = worker,
        .arena = a,
        .pending = try fixture.next(service, worker, a),
    };
    if (!std.meta.eql(author.pending.task, task)) return error.UnexpectedFixtureTask;
    try fixture.checkInitialBinding(service, a, author.pending);
    const source = try sources.fixtureForwarder(a);
    const built = try author.perform("program", .{ .build = .{
        .source = .{ .json_text = .{ .bytes = source } },
        .source_kind = .source_records,
        .exposures = .{ .items = &.{} },
    } });
    const program = try fixture.reference(a, built, "program");
    const schema = try fixture.reference(a, built, "input_schema");
    var changed = evidence;
    changed.domain.identity ^= 1;
    changed.domain.revision ^= 1;
    const Visit = @TypeOf(evidence.visits).Child;
    const altered_visits = try a.dupe(Visit, evidence.visits.items);
    if (altered_visits.len == 0) return error.MissingDevelopmentVisit;
    altered_visits[0].observed ^= 1;
    changed.visits = .{ .items = altered_visits };
    const forged = try apply(&author, program, schema, canonical_input, changed);
    const valid = try apply(&author, program, schema, canonical_input, evidence);
    try report(&author, program);
    var receipt = try native.values.toJson(Application, a, valid);
    try Json.put(a, &receipt, "program", try native.values.toJson(wc.Ref, a, program));
    try Json.put(a, &receipt, "invalid_view", try native.values.toJson(wc.Ref, a, forged.view));
    try Json.put(a, &receipt, "source", Json.string(source));
    return receipt;
}

const Application = struct {
    consumer: wc.Ref,
    input: wc.Ref,
    work: wc.Ref,
    result: wc.Ref,
    view: wc.Ref,
};

fn apply(
    author: *Author,
    program: wc.Ref,
    schema: wc.Ref,
    source: wc.Ref,
    evidence: sources.ScanEvidence,
) !Application {
    const a = author.arena;
    const inspected = try author.perform("context", .{ .inspect = .{
        .page = .{},
        .consumer = .{ .target = .{ .controller = .{} } },
    } });
    const consumer = try fixture.reference(a, inspected, "consumer");
    const materialized = try author.perform("context", .{ .materialize = .{
        .input = .{ .value = .{ .inline_json = .{
            .schema = schema,
            .json_text = .{ .bytes = try sources.projectionInput(a, consumer, evidence) },
        } } },
        .sources = .{ .items = &.{source} },
    } });
    const input = try fixture.reference(a, materialized, "value");
    const run_result = try author.complete(program, input);
    const result = try fixture.reference(a, run_result, "result");
    const selection = try author.perform("context", .{ .select = .{ .projected = result } });
    return .{
        .consumer = consumer,
        .input = input,
        .work = try fixture.reference(a, run_result, "work"),
        .result = result,
        .view = try fixture.reference(a, selection, "view"),
    };
}

fn report(author: *Author, program: wc.Ref) !void {
    const a = author.arena;
    const summary = try std.json.Stringify.valueAlloc(a, .{
        .kind = "interface-repair.candidate.v1",
        .status = "candidate",
        .program = .{ .kind = @tagName(program.kind), .id = program.id.bytes },
        .diagnosis = "The Boolean omits domain coverage; the selected program forwards the scan.",
    }, .{});
    try submitReport(author, summary, "The candidate forwards the scan.");
}

fn submitReport(author: *Author, summary: []const u8, statement: []const u8) !void {
    const a = author.arena;
    const arguments = try std.json.Stringify.valueAlloc(a, .{
        .summary = summary,
        .claims = .{.{
            .kind = "observation",
            .statement = statement,
            .reasoning = "The rendered computed block carries the domain and visits.",
            .evidence_indices = .{@as(u64, 0)},
        }},
        .limitations = .{"Controlled offline fixture."},
    }, .{});
    try fixture.acquire(author.service, a, author.pending, "report", arguments);
}

pub fn answer(
    service: *Service,
    worker: *native.testing.Worker,
    a: Allocator,
    task: [16]u8,
    summary: []const u8,
) !Json.Value {
    var author: Author = .{
        .service = service,
        .worker = worker,
        .arena = a,
        .pending = try fixture.next(service, worker, a),
    };
    if (!std.meta.eql(author.pending.task, task)) return error.UnexpectedFixtureTask;
    const arguments =
        \\{"command":{"tag":"materialize","value":{"input":{"tag":"snapshot",
        \\"value":{"path":"scan.json","offset":0,"maximum":4096}},"sources":[]}}}
    ;
    const parsed = try Json.parse(a, arguments, .{});
    _ = try fixture.action(service, worker, a, &author.pending, "context", parsed.value);
    try submitReport(&author, summary, "The scan manifest identifies the declared universe.");
    return Json.object();
}
