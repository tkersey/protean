# Protean

This example runs one authored computation on the existing native host. The
model can call `inference_set` and `skill_set`; the host admits their proposed
next request before the computation commits the new control revision.

This is Protean's supported application. It uses the reusable Zig authoring and
native-host APIs; Horos owns compiled control and Kronos owns continuation.

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
skills, offers, budgets, epochs and next actions stay in that authored program.
The native adapter realizes its explicit requests; it has no transcript-driven
policy loop. See the [v6 API contract](../../docs/model-invocation-v6.md).

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

The prebuilt reference embeds the same BPI3 and runs it through native Kronos.
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

A configured reference uses `validate --config FILE`, then:

```sh
./zig-out/bin/protean run --config ./approved-adaptive.json \
  --input-json '{"task":"Explain the entry point using source evidence."}' \
  --state-dir ./adaptive-task
./zig-out/bin/protean serve --transport stdio \
  --config ./approved-adaptive.json --state-dir ./adaptive-task
```

Inference additionally requires `--authorize-inference --credential-file FILE`.
Configuration and discovery alone perform no inference or credential discovery.
Use `--help` for status, result, response, resume, cancellation and checkpoint
commands. The CLI and `agent-host/1.0` front end use the same image and native
task owner. Protocol callers may use any language; the existing optional
[`stdio-client.mts`](../../test/support/stdio-client.mts) is a caller, not an agent
runtime dependency. Questions require the reported identity/revision/digest;
queued follow-ups cannot substitute for a question response. Stable client
operation IDs support lost-ack retries, not new inference after unknown delivery.

SQLite, the existing C shim, libc and OS facilities remain admitted native
dependencies. Zig and setup/build tools are authoring dependencies; JavaScript
qualification controllers stay outside the deployed product boundary. Distributed
adaptive mobility is future work; checkpoint copying does not transfer custody.

## Frozen configuration

[`adaptive.example.json`](adaptive.example.json) is a disabled-by-default launch
template, not a model approval. Replace both model placeholders with approved
Responses IDs, check their declared feature flags, and select your read-only
snapshot. Paths are relative to the launch working directory. The template and
skill files accompany the native reference artifacts. Configuration alone never
authorizes inference; the launch flag and explicit credential file are separate.

Configuration has these fields:

- `workspace`, `snapshot_root`, `endpoint`, `audience`;
- `profiles`, `initial_profile`, `initial_effort`;
- `skills`, `maximum_model_calls` (1–16), `maximum_control_revision` (0–16).

Every profile declares `id`, actual API `model`, `reasoning_mode`,
`reasoning_context`, `efforts`, `effort_update`, `explicit_cache`,
`additional_tools`, `cache_diagnostics`, `opaque_family`, `max_output_tokens`,
`request_bytes`, `response_bytes`, and `timeout_ms`. Profiles that admit `effort_update: true` use append-only configuration updates
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
No skill executes scripts or installs code. Markdown is admitted before task
creation (32 KiB per body, 128 KiB total). The shared catalog format allows 32
entries; this deployment admits 32 (including the built-in construction skill),
subject to the native host's 64 frozen resource slots. Snapshot and skill catalog use two slots; construction-enabled
configuration also stores its component catalog and admitted input values.
At most four skills may be active.
The complete frozen resource set, including the snapshot, must fit 16 MiB.
Context and continuation limits can reject a
proposed transition before it is acknowledged.
The task admits four answers and follow-ups in total. At that limit it stops
offering questions and polling the inbox; later queued messages remain retained
and are reported as not consumed when the task finishes.

The adaptive model reply has a 16 KiB aggregate projection ceiling, independent
of the 512 KiB raw response ceiling. An oversized projection returns a typed
capacity result, retains its captured response and observed usage, and does not
trigger another provider attempt. The full allowed combinations remain subject
to the existing Kronos, worker, object and namespace budgets.

The snapshot, skill bytes, catalog, profiles and limits are frozen into task
resources. Reopening reads those bytes. Editing a configuration or Markdown
file cannot update a saved task; supply a new task for new authorization.

## Construct and reuse a pure tool

The `tool-construction` skill exposes a frozen catalog of compiled BMO1
components. `tool_build` links a bounded recipe with Horos's data-only
linker; `tool_run` executes the resulting BPI3 with native Kronos. Neither invokes
the Zig compiler, another model, or a host interpreter for the recipe. Generated
programs receive ordinary values and cannot perform external effects.

Enable this explicitly with configuration version 2:

```text
schema: "adaptive-agent.configuration.v2"
adaptive: the complete original configuration object described above
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
Each table has at most 32 rows, 32 related records and 32 selected keys. Up to
four inputs may be frozen. The original unversioned configuration and its eight
skill bits retain their meanings and enable neither new operation.

Version 2 admits the exact developer-owned skill automatically. Loading it
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

Exhausted construction and execution allowances remove those tools from future
offers using the native attempt records. Captured allowance observations replay
unchanged across restart. `inspect` accepts source-file evidence only; generated
results remain reportable, and selecting one for inspection returns a recoverable
tool rejection.

The model-facing recipe limit is 2,700 bytes so worst-case escaping fits the
existing 16-KiB argument envelope. The native construction API has an 8-KiB
upper ceiling. Both enforce at most 16 instances, 64 bindings, an acyclic
inter-instance graph, and 128-KiB catalog/image assets. Each task permits four
physical build attempts and eight runs, including failed attempts and retries,
within its existing twelve-work-call allowance. Runs admit 32-KiB values,
one million cumulative Kronos transitions, and a ten-second checked deadline;
cancellation and time are checked between 256-transition quanta. The existing
16-MiB worker allocation region also covers decoding, linking and publication.
Limits intersect: an individually valid value can still exceed a combined
worker or model-envelope budget and receive an explicit failure.

Application version 2 reports `adaptive-agent.output.v2`: each evidence entry
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

Work results and control receipts are immutable artifacts. Kronos continuations
retain references, not duplicated source excerpts or directory pages. The
current model call's offered set is checked independently from materialized
definitions, and work dispatch binds to that captured call. Queued user messages
are consumed through the authored inbox only after the current call settles.

The new contracts are `agent.model.invoke.v6` and
`agent.model.context.responses.adaptive.v4`. Shared earlier schema meanings
remain intact; the fixed applications are retired. Reports expose bounded evidence
and control receipts; raw provider captures and opaque reasoning are not public
report artifacts. Absent usage remains unavailable. Explicit cache markers and
unchanged request prefixes do not establish provider cache reuse.
