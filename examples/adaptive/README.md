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
`protean.adaptive_controls.defineSkill(P, ...)`, `P.declareAdaptive`, and
`protean.responders.defineAdaptiveModelObserved`. They build ordinary Horos
computations and checked contracts. [`definition.zig`](definition.zig) composes
them with this consumer's task, evidence, question, inbox and completion logic;
[`types.zig`](types.zig) supplies its actions and ordinary schemas. Model choice,
skills, offers, epochs and next actions stay in that authored program.
The native adapter realizes its explicit requests; it has no transcript-driven
policy loop. See the [v10 API contract](../../docs/model-invocation-v10.md).

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
`agent-host/2.0` interface and CLI share the same image and task owner. Questions
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
qualification controllers stay outside the deployed product boundary. Distributed
adaptive mobility is future work; checkpoint copying does not transfer custody.

## Frozen configuration

[`adaptive.example.json`](adaptive.example.json) uses
`adaptive-agent.configuration.v3`. It contains `adaptive` and `tools` fields;
`tools: null` leaves construction unadmitted. Paths are relative to the launch
working directory. The `adaptive` object contains:

- `workspace`, `snapshot_root`, `endpoint`, `audience`;
- `profiles`, `initial_profile`, `initial_effort`;
- `skills`.

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

## Construct and reuse a pure tool

The `tool-construction` skill exposes a frozen catalog of compiled BMO1
components. `tool_build` links a recipe with Horos's data-only
linker; `tool_run` executes the resulting BPI3 with native Kosmos. Neither invokes
the Zig compiler, another model, or a host interpreter for the recipe. Generated
programs receive ordinary values and cannot perform external effects.

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

The host supplies each input's opaque reference in the initial bindings. All
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

The model passes that complete JSON as the string field `proposal_json` to
`tool_build`. Its successful response says `structurally_admitted`, supplies
`tool_ref`, and identifies the actual input, output and failure schemas. It
does not establish that the composition meets the task. A subsequent
`tool_run` call takes that `tool_ref` and an admitted `input_ref`; its result
contains the actual computed table. The same tool reference can run on the
second compatible input after a normal parent restart.

Construction is offered only while the skill is active and policy allows it.
Execution has an independent `run` permission; deactivation or unload does not
destroy a constructed program. After unload, the parent exposes retained tool
references without reinserting the removed instructions. References from a
different task or policy do not confer authority.

`inspect` accepts source-file evidence only; generated results remain reportable,
and selecting one for inspection returns a recoverable tool rejection.

Recipes require unique instance keys, schema-compatible bindings and an acyclic
inter-instance graph. There is no recipe/count/image-size allowance. Generated
execution validates the retained derivation and runs the exact referenced image;
it does not replace the artifact or ask another model to synthesize a program.
Failed attempts remain recorded and do not suppress otherwise authorized tools.

Application version 3 reports `adaptive-agent.output.v3`: each evidence entry
is tagged `source` or `generated`, and constructed program references are
retained in `programs`. `report.evidence_index` selects the stable acquired
evidence list. Old saved tasks retain their original image/runtime bindings and
must use their original compatible executable; no implicit migration occurs.

Use the existing `artifact.read` method with `task_id` and the reference's
hex digest as `artifact_id` to inspect a generated program or result in bounded
chunks. `ToolProgram` and `ToolArtifact` in the application metadata describe
their ordinary wire values. Disclosure requires that the producing capability
explicitly permits public output objects; raw captures, prepared requests and
private context objects remain unavailable.

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

The current adaptive contracts are `agent.model.invoke.v10`,
`agent.model.context.responses.adaptive.v5` and `agent.model.policy.adaptive.v2`.
Old saved tasks retain their original contracts and require their original
compatible executable. Raw provider captures and opaque reasoning remain private.
Absent usage remains unavailable. Explicit cache markers and unchanged request
prefixes do not establish provider cache reuse.

## Qualification status

Deterministic checks cover 38 continuing model calls across restart/import,
17 control revisions, 12 generated runs, larger catalogs/resources/snapshots,
large-prompt artifact reads, and honest recovery from failed capture publication.
These use controlled provider replies. They do not establish real model access,
actual configuration-update acceptance, a provider cache hit, or live task quality.
Live qualification requires an explicitly supplied credential binding. Record the
exact source/dependency/program/executable identities, UTC run times, returned
models, effective efforts, physical attempts, usage and useful outcomes in the PR.
