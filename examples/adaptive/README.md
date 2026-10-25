# Protean

This example runs one authored computation on the existing native host. The
model can call `inference_set` and `skill_set`; the host admits their proposed
next request before the computation commits the new control revision.

This is Protean's supported application. It uses the reusable Zig authoring and
native-host APIs; Horos owns compiled control and Kosmos owns continuation.

Linux reference qualification uses recorded provider replies and controlled I/O.
The [acceptance map](../../docs/adaptive-responses-acceptance.md) binds the current
obligations to proof surfaces and exact-head PR evidence.

## Author and build

The reusable owners are `protean.adaptive_controls.defineInference`,
`protean.adaptive_controls.defineSkill(P, ...)`, `P.declare`, and
`protean.responders.defineModelObserved`. They build ordinary Horos
computations and checked contracts. [`definition.zig`](definition.zig) composes
them with this consumer's task, evidence, question, inbox and completion logic;
[`types.zig`](types.zig) supplies its actions and ordinary schemas. Model choice,
skills, offers, epochs and next actions stay in that authored program.
The native adapter realizes its explicit requests; it has no transcript-driven
policy loop. See the [v11 API contract](../../docs/model-invocation-v11.md).

From the Protean repository after the [native setup](../../docs/native-single-binary.md):

```sh
zig build protean -Doptimize=safe
```

This produces the reference executable `zig-out/bin/protean` and the
identifiable program/contract outputs:

```text
zig-out/protean/adaptive/program.bpi3
zig-out/protean/adaptive/application.json
```

`zig build protean-image` emits those program/contract outputs without
building another application shell. The application metadata contains ordinary
wire schemas and approved resource identities. Their meaning does not depend
on an executable pathname or package layout.

For another consumer, use the same authored controls and checked responder
with that consumer's action/catalog types. For native embedding, the existing
`build.zig.addNativeSystem` / `build_native.zig` entry accepts definition, types
and environment paths. Its `.application.emitted` option reuses exact compiled
image/assets/types; the repository reference already uses it. That is also the
public path used by downstream native hosts.

## Execute the compiled program

```sh
./zig-out/bin/protean describe-build
./zig-out/bin/protean demo --offline --state-dir ./adaptive-demo
```

The prebuilt reference embeds the same BPI3 and runs it through native Kosmos.
It does not execute `.zig` source or invoke a compiler, Node, Python or a helper
service. Separate image and contract files are build/inspection outputs, not
additional launch dependencies of this existing embedding. Exact image, assets,
runtime and task-resume identities remain enforced; another packaging layout
does not authorize grafting old state onto a different build.

`demo --offline` uses embedded source and recorded function-call replies. It
exercises resident and transient skills, a skill-specific inspection permission,
model/effort changes, deactivation, hard unload, return to an earlier profile,
a question and a report. This script is an explicit fixture input, not the
production decision loop.

For live execution, copy `adaptive.example.json`, set the snapshot and skill
paths, then validate and launch with an explicitly supplied credential file:

```sh
./zig-out/bin/protean validate --config ./approved-adaptive.json
./zig-out/bin/protean run --config ./approved-adaptive.json \
  --authorize-inference --credential-file /absolute/path/to/private-key-file \
  --input-json '{"task":"Explain the entry point using source evidence."}' \
  --state-dir ./adaptive-task
```

Use a new state directory for the new build. The maintained template starts at
`gpt-6-astra`, `medium`, standard mode and also admits `gpt-6.1-sol`. Configuration
and discovery do not perform inference. `demo --offline` remains deterministic.
The credential file must be private to the current user; its contents are never
part of task resources or prepared provider requests.

For an interactive continuing task, launch `serve --transport stdio` with those
same configuration, authorization, credential and state flags. The
`agent-host/2.1` interface and CLI share the same image and task owner. Questions
require the returned identity/revision/digest; queued `task.message` follow-ups
use a distinct interface. Stable operation IDs support lost-ack retries. Unknown
external delivery never authorizes another provider attempt.

Use `status`, `result`, `respond`, `resume`, `cancel`, `export-checkpoint` and
`import-checkpoint` as described by `--help`. Restart with `--profile-task ID`
to restore the original frozen configuration and resources. Import into a fresh
namespace, and do not run source and copied tasks concurrently as if custody
had transferred. The optional [stdio client](../../test/support/stdio-client.mts)
is an external caller, not a runtime dependency.

SQLite, the existing C shim, libc and OS facilities remain admitted native
dependencies. Zig and setup/build tools are authoring dependencies; JavaScript
qualification controllers stay outside the deployed product boundary. Placement
transfers custody through authenticated peers; checkpoint copying does not.

Active observer subscriptions remain co-located with their source work. Moving
either work separately rejects before freezing. A controller move also rejects
while an active subscription uses `owner_scheduled` continuation. Explicit-only
subscriptions may stay at the source when their controller moves; task shutdown
stops them through signed remote controls. Stopped or superseded observer work
remains portable with its original source and result provenance.

## Frozen configuration

[`adaptive.example.json`](adaptive.example.json) uses
`adaptive-agent.configuration.v3`. It contains `adaptive` and `tools` fields;
`tools: null` leaves construction unadmitted. Paths are relative to the launch
working directory. The `adaptive` object contains:

- `workspace`, `snapshot_root`, `endpoint`, `audience`;
- `profiles`, `initial_profile`, `initial_effort`;
- `skills`.

The optional `semantic_construction` field defaults to `null`. An operator can
enable derived runtime admission with
`{"roots":["<64 lowercase hex digits>"],"checkers":["<exact checker identity>"],"guard":true}`.
The roots must name the actual ancestors approved by the operator.
`program.inspect` semantic-source summaries report `root_identity`, and
`program.describe` with `semantic_candidates` reports `checker_identity` and the
active allowlists. Construction and execution also require the ordinary `tools`
permissions. A constructed candidate remains inert until validation succeeds;
`guard` separately permits bounded comparison against the trusted reference.
The policy contributes to the frozen profile identity. Restart and destination
import require an explicit current `--config` containing the approved policy;
restoring or importing frozen profile bytes alone never installs native trust.

There are no model/work/control/question/build/run allowances. Old unversioned
and v2 configurations require their original compatible build.

Every profile declares `id`, actual API `model`, `reasoning_mode`,
`reasoning_context`, `efforts`, `effort_update`, `explicit_cache`,
`additional_tools`, `cache_diagnostics`, `opaque_family`, `max_output_tokens`,
`request_bytes`, `response_bytes`, and `timeout_ms`. The last four fields are optional values: `null` imposes no
application cap; an explicitly selected positive value retains its stated
meaning. The maintained live template uses `null` for all four. Profiles that admit `effort_update: true` use append-only configuration updates
after settling the actual control call. Request-level effort stays unchanged;
the replayed update selects effective effort. A false declaration changes the
request-level effort without discarding visible history. Features are
explicit approvals, not inferred from model-name prefixes. Supply actual
operator-approved models and capabilities; fixture names are not live models.

Each skill declares `id`, `version`, a short `description`, a `markdown` file,
and eight `tools` booleans in this order: list, read, ask, report, stop,
inference_set, skill_set, inspect. The first seven are core tools. `inspect` is
a lexical guard-line count over previously acquired evidence and is available
only while a loaded approved skill grants it. It does not prove correctness.
No skill executes scripts or installs code. Skill bodies, catalogs and the
ordered frozen resources use variable-length values. Skills do not disappear
because a counter reaches a framework-selected number.

The snapshot, skill bytes, catalogs and profiles are frozen into task resources.
Reopening reads those exact bytes. Editing a configuration or Markdown file
cannot update a saved task; new authorization requires a new task.

## Capacity and accounting

Model/work counts, control revisions, physical attempts, captures and returned
usage remain distinct durable facts. Replay of an acquired response is not a
new provider attempt. Counters use checked arithmetic; no wrap or saturation
creates another identity. Public 64-bit values use decimal strings.

Growing evidence, program and receipt collections retain immutable object
references in acquisition order. Conversation history stays with the existing
context owner. There is no cumulative call, time, token or spending allowance,
fixed worker/SQLite heap, or application namespace-size quota. Requests and
responses allocate their actual encoded sizes. A provider restriction, explicit
profile constraint, allocation failure or storage failure remains observable.

Execution uses cancellable 256-transition quanta without a cumulative fuel or
ten-second stop. Protocol frames, concurrent scheduling/backpressure windows,
32 KiB artifact chunks, 128-event pages and 4 KiB source-read pages bound a unit
of work, not its lifetime. Complete large results and questions are retained as
artifacts. Status includes the total pending-message count and a bounded view;
`task.events` supplies the complete message history. SQLite's actual linked-library
limits, archive integer fields, checked machine arithmetic and OS capacity still
apply. Finite tests do not establish infinite capacity or termination.

## Construct and retain computations

Application 5 exposes `program`, `work`, and `context` alongside ordinary reads,
questions, reports, and adaptive controls. Computation is optional. A pending
child question never narrows the controller to the child's answer type.

`program.describe` returns paged source-record schemas, examples, component
interfaces, or binding contracts. `program.build` accepts existing Horos source
records (`source_kind: "source_records"`) or a frozen component recipe
(`"component_recipe"`). The source is a `json_text` string or an authorized
source reference. Compilation uses the linked Horos checker/lowerer; execution
uses native Kosmos. Neither requires a compiler executable or a source checkout.
The build worker does not run the program or invoke a model. Admission establishes
structural validity, not that the algorithm answers the user's question.

Enable this explicitly with configuration version 3:

```text
schema: "adaptive-agent.configuration.v3"
adaptive: the complete adaptive configuration object described above
tools: the object below
```

For example, the `tools` object can admit two compatible inputs:

```json
{
  "build": true,
  "run": true,
  "reconstruct": false,
  "inputs": [
    {
      "id": "first",
      "description": "Selected lock records and related source records.",
      "rows": [{"id":"1","key":"10","value":"100","group":"1"}],
      "relation": [{"id":"11","key":"10","value":"100","group":"1"}],
      "selected": ["10"]
    },
    {
      "id": "second",
      "description": "The lock value changed; reuse the same procedure.",
      "rows": [{"id":"2","key":"10","value":"101","group":"1"}],
      "relation": [{"id":"11","key":"10","value":"100","group":"1"}],
      "selected": ["10"]
    }
  ]
}
```

The host lists authorized input IDs in the initial bindings.
`context.materialize` with `input: {tag: "authorized_input", value: "first"}`
returns its typed value reference and provenance. All
64-bit numbers use decimal strings. Admission converts these records to the
ordinary `Table` schema and initializes result fields; it performs no audit.
Table rows, related records, selected keys and the admitted input collection
use variable-length sequences. The compiled component catalog remains the exact
authority for composition; more capacity does not grant new components.

A non-null `tools` object admits the developer-owned construction skill. Loading it
introduces its instructions, recipe JSON schema and complete machine-derived
component signatures at the normal skill context position. This checked recipe selects matching rows
and is a small working example, not a complete audit:

```json
{
  "instances": [
    {"key":"select","component_id":"filter"},
    {"key":"predicate","component_id":"selected"}
  ],
  "bindings": [{
    "required":{"instance":"select","symbol":"keep"},
    "supplied":{"instance":"predicate","symbol":"apply"}
  }],
  "entry":{"instance":"select","symbol":"apply"}
}
```

Pass the recipe JSON as the string in this `program` action:

```json
{"command":{"tag":"build","value":{"source":{"tag":"json_text","value":"RECIPE_JSON"},"source_kind":"component_recipe","exposures":[],"role":"computation"}}}
```

A successful response is `admitted` and contains `observation.program`, actual
input/result/failure descriptors, source provenance, and ports. Source records
can define new algorithms, recursive functions, and recursive schemas. They
cannot create native callbacks or claim protected model/commit identities.

Start the returned program with a compatible value reference:

```json
{"command":{"tag":"start","value":{"program":{"kind":"program","id":"PROGRAM_DIGEST"},"input":{"tag":"reference","value":{"kind":"value","id":"VALUE_DIGEST"}},"policy":{"stop":"terminal","continuation":"owner_scheduled"}}}}
```

Use `next_slice` or `next_exposed_event` instead of `terminal` to choose a smaller
commitment. `explicit_only` retains the successor without scheduling more work.
`owner_scheduled` permits mechanical progress to the chosen stopping condition;
it does not require an inference per quantum. `work.inspect` does not execute.
`work.collect` returns requested work in order, including missing and pending
results. `work.wait` yields until selected observations change or a user message
arrives. A kernel boundary remains parkable/cancellable even without authored ports.

Source exposures name an actual effect index and `observation`, `input`, or
`alternative` class. The ordinary compiled driver retains typed futures. An
alternative port invokes an admitted multi-shot resumption; it does not copy an
external checkpoint. `work.interact` binds the work's execution/control revisions,
port identity, and generation. Repeated `resume_value` commands at an alternative
port create actual alternatives while retaining the template. `finish` disposes
the retained future. Illegal exclusive or cleanup captures remain compiler errors.
The model may choose zero alternatives or leave an input port unanswered.

For example, after a child asks for a binary classification, the controller can
use `context.expand` to inspect omitted source, `work.park` the child, and
`program.build` a different identity comparison. There is no native transition
for that investigative decision. The original port still accepts its original
type if the model later resumes it.

`context.materialize` admits exact typed values or snapshot slices with coverage
and provenance. `context.select` chooses retained values for a subsequent model
request; `context.expand` exposes source, value, or view pages. Views preserve
raw evidence access and cannot remove policy, current user messages, skills, or
authorized actions. A view change leaves an already-prepared request unchanged.
Old research exchanges and opaque reasoning are removed at the next context epoch.

`work.delegate` explicitly selects a policy and optional interpretation: `none`,
`snapshot`, or `model`. A model binding names an authorized profile/effort,
subproblem, typed target port, and input references. The resulting child has its
own occurrence, capture, and provenance. A pending port alone grants no inference.
Captured, unknown, rejected, cancelled, and completed states remain distinct.
Cancellation cannot turn ambiguous external delivery into a completed answer.

Build and execution permissions are independent of construction-skill residency.
Unloading a skill removes its instructions without destroying retained programs.
Every reference is checked against task custody; a digest grants no authority.
Recipes still require unique keys, compatible bindings, and acyclic component
wiring. General source recursion is governed by Horos, not that recipe restriction.

Application version 5 reports `adaptive-agent.output.v5`. Its `result` is one
of `report`, `no_result`, `refusal`, or `capacity`. A report has a summary,
claims, and limitations. Each claim states its kind (`observation`, `inference`,
or `hypothesis`), statement, reasoning, and zero-based `evidence_indices`.
Observations and inferences require citations; inferences and hypotheses require
reasoning. At least one claim must cite evidence. Invalid proposals receive a
typed rejection under the original tool-call ID and can be corrected.

The output retains every acquired evidence entry in its original order, tagged
`source` or `workspace`, plus constructed program references in `programs`.
Claims may share evidence; a claim cannot repeat an index. These checks establish
membership and structural support, not the truth of model-written statements.
Application 8.0.0 uses context v7 and native state format 19 in a **new namespace**.
Keep an existing task's namespace, original image, and exact executable together;
continue it with that executable. Do not point the new binary at its old namespace
or transplant the old continuation. Building this repository does not update an
installed runtime. Preserve the previous executable and its `describe-build`
output before installing a replacement, and keep the old namespace discoverable.

Workspace inspection and expansion return bounded pages with completeness and
coverage. Raw provider captures, prepared requests, and private context objects
remain private; possession of their digest does not make them public artifacts.

## Controls and context

Both tools require `expected_revision` and a bounded `reason`. The inference
control selects an approved profile and supported effort. The skill control
specifies `operation` (`load`, `deactivate`, `unload`), exact `skill_id` and
`version`, and `residency` (`resident`, `transient`, `unchanged`). Load requires a
residency; removal operations require `unchanged`. Changing residency requires
an explicit unload followed by load. Repeating an already satisfied selection
is a no-op, while a stale revision rejects.

Resident deactivation retains its body and definitions but removes its offers.
Unload advances the eviction revision and physically removes the owned skill
injection and exclusive definitions. It removes opaque reasoning that could
have observed that skill, retaining unrelated opaque output and ordinary
evidence—even when evidence contains identical text. The Horos computation
resumes with its existing task state, transcript and evidence references. Model
changes retain visible messages and settled tool exchanges while excluding old
opaque reasoning and old-profile effort updates. No task-state handoff bundle is
constructed. Original captures remain immutable audit evidence.

Work results and control receipts are immutable artifacts. Kosmos continuations
retain references, not duplicated source excerpts or directory pages. The
current model call's offered set is checked independently from materialized
definitions, and work dispatch binds to that captured call. Queued user messages
are consumed through the authored inbox only after the current call settles.

The current adaptive contracts are `agent.model.invoke.v11`,
`agent.model.context.responses.adaptive.v7` and `agent.model.policy.adaptive.v2`.
Start new tasks in fresh state under these contracts; retain old tasks with their original runtime.
Raw provider captures and opaque reasoning remain private.
Absent usage remains unavailable. Explicit cache markers and unchanged request
prefixes do not establish provider cache reuse.

## Qualification status

Deterministic checks retain the long continuing model trace across restart/import,
17 control revisions, 12 generated runs, larger catalogs/resources/snapshots,
large-prompt artifact reads, and honest recovery from failed capture publication.
These use controlled provider replies. They do not establish real model access,
actual configuration-update acceptance, a provider cache hit, or live task quality.
Live qualification requires an explicitly supplied credential binding. Record the
exact source/dependency/program/executable identities, UTC run times, returned
models, effective efforts, physical attempts, usage and useful outcomes in the PR.

The [workspace acceptance map](../../docs/computational-workspace.md) identifies
the source/native/owner witnesses and their limits. The optional
[three-arm evaluation](../../tools/evaluation/README.md) records model efficacy
only after explicitly authorized live runs and result adjudication.

### Reconstruct the task controller

Application 7 exposes the active controller through `program.describe` with
`section: "current_controller"`; its source reference expands through `context`.
Set `tools.reconstruct` to `true` to permit same-task adoption, keeping the existing
build and run grants. New computation builds use `role: "computation"`; controller
source builds use `role: "controller"`. Every `work.start` supplies `trial`, using
`{"tag":"none","value":{}}` for ordinary computation.

The protected model context supplies the current epoch and handoff identity.
`program.adopt` selects a controller program and pure carry converter using those
exact values. Its `trial` is `none` or a selected trial work reference. A successful
handoff starts the successor; it does not return into the old controller. Failed
preparation returns an ordinary diagnostic. Replacement and trials are optional.
See [controller contracts and continuity](../../docs/computational-workspace.md#reconstructing-the-active-controller)
for schemas, cleanup, provenance and historical-resume boundaries.
