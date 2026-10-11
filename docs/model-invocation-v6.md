# Adaptive Responses contract (v6)

`agent.model.invoke.v6` adds separately bound inference selection and context
projection to the existing model/responder owner. It does not change v3, inline
v4, or the fixed-profile v5 contract. The reference consumer is
[`protean`](../examples/adaptive/README.md).

## Authored API and execution

Scope authority is the October 9, 2026 **authored program on Horos, executed
by Kronos** amendment. It supersedes dual-adaptive-backend and immediate
standalone-distribution gates without changing these effect identities.

`protean.adaptive_controls.defineInference` and `defineSkill(P, ...)` construct
reusable control transitions. `P.declareAdaptive` and
`protean.responders.defineAdaptiveModelObserved(P, ...)` provide the admitted model
effect and checked continuation. These owners are independent of the repository
example. Consumers compose them through existing Protean/Horos authoring;
Kronos executes the emitted BPI3 and owns its saved continuation.

The program owns task state, inference selection, skill residency, revisions,
projection revisions, D/O masks, logical budgets and completion. Native Zig
adapters perform deterministic bounded projection, provider I/O and storage at
explicit effect boundaries. They cannot choose the next action from a transcript,
substitute a model, mutate a skill, reset an epoch or retry unknown delivery.

The existing native reference embedding and build helper remain supported.
`protean-image` emits BPI3 and ordinary wire contracts; `protean`
adds the existing native reference vehicle. A prebuilt vehicle does not invoke
the Zig compiler or require an adaptive JS runtime. Separate final distribution
polish is deferred, not a blocker on the reusable API or reference integration.

## Ownership and identities

| Value | Meaning and owner |
| --- | --- |
| Frozen task profile and ordered resources | Existing native grant identity. Contains the approved universe and limits for this task. |
| `AdaptiveSelection.profile_id/profile_digest` | One approved inference entry; the digest covers its ordinary encoded value. It cannot replace the task policy. |
| `control_revision` | Authored configuration revision. Separate from native task revision, message ordinal, provider call ID, and physical attempt count. |
| `AdaptivePlan.epoch/watermark` | Explicit projection lineage and committed response position. |
| `eviction_generation` | Authored exclusion fence. Every newly selected lineage must respect it. |
| `AdaptiveContextReference` | Content reference plus schema, policy, inference selection, task, tenant, audience, epoch, watermark, and eviction bindings. |

The additional identities are `agent.model.context.responses.adaptive.v4` and
`agent.model.policy.adaptive.v1`. The v5
`agent.model.context.responses.v1` reference is not an adaptive reference.

## Requests and checked actions

`P.AdaptiveRequest` contains the ordinary invocation, frozen policy digest,
selection, projection plan, materialized mask, offered mask, and settled tool
results. `defineAdaptiveModelObserved` derives definitions from the compiled
catalog and captures the original offered set with the continuation.

The three sets have distinct meanings:

- **C:** compiled action variants, schemas and codecs;
- **D:** definitions materialized from C by the core and loaded skills;
- **O:** actions currently callable, within D and the active frozen permissions.

Retaining a definition does not retain its execution permission. The responder
admits against original O. Application work additionally binds to the original
captured call, task, snapshot and exact native resource role. The adaptive
model identity remains protected against raw model-effect authoring bypasses.

An inference profile explicitly declares its model, efforts, reasoning mode and
context, feature flags, opaque-family label, output-token maximum, byte bounds
and timeout. No feature is inferred from a model-name prefix. An admitted `effort_update: true` keeps the original top-level effort and
appends a configuration update after the actual settled control result. The
rendered update sequence is folded to validate effective effort again before
dispatch. With `effort_update: false`, the request-level effort changes, but
visible history is still retained. A logical epoch revision does not itself
replace the transcript.

## Projection and eviction

The core instructions and metadata remain fixed within a task. Work results,
user input, tool additions and resident bodies appear at their actual history
positions. Transient bodies are appended after committed history and are not
copied into it. Their subsequent movement therefore limits the genuinely
unchanged visible prefix.

Explicit caching places a marker on the epoch core and the latest newly
appended eligible input-text block, including eligible tool-result content.
Earlier markers retain their positions. At most two new marker positions are
selected in one request; no marker is inserted into `additional_tools` or opaque
provider items. Transient suffixes follow all selected boundaries. The field
locations and diagnostic comparison request follow the official
[prompt-caching guide](https://developers.openai.com/api/docs/guides/prompt-caching)
and [diagnostics guide](https://developers.openai.com/api/docs/guides/prompt-caching/diagnostics).
These documents do not establish live acceptance or a cache hit.

Resident deactivation removes offers while retaining material. Hard unload and
transient deactivation remove owned injected instructions and exclusive tool
definitions. Projection records each injected body's catalog identity; it never
identifies an injection by searching for equal text in evidence. Each opaque
output records the approved skills it could have observed, including dependency
carried by retained opaque output. Body eviction excludes dependent opaque output while preserving unrelated output,
including inactive intervals. Definition removal separately excludes opaque output
that could have observed a removed tool definition. Retained tool additions must
satisfy the destination profile; cache markers are removed when it disables
explicit caching.

Model changes preserve compatible visible messages and complete settled
call/result exchanges. They exclude old opaque reasoning and old-profile
configuration updates. Skill eviction preserves current effort updates and the
original top-level effort. Unchanged input prefixes and their cache breakpoints
are retained; stale breakpoints in an edited suffix are replaced by the current
eligible suffix boundary. Shared provider cache across models is not assumed.

The reference program uses Horos resumptions through Kronos to retain task
state, evidence references, control state and pending results. It no longer
constructs a second JSON representation of task state for ordinary transitions.
Explicit replacement contexts are retired: a plan continues its prior transcript
and cannot supply replacement messages for an existing context.

Context schema v4 retains per-item projection provenance and removes replacement
seeds from the embedded plan. Exact application,
image, schema and runtime bindings remain recovery gates; old saved tasks are
not migrated or reinterpreted under a new build.

## Acquisition and replay

Native execution reuses `CaptureAdapter.prepare/acquire/interpret` and the
existing task owner. Preparation fixes the exact request, selection and plan.
Dispatch charges a durable physical attempt. Capture is committed before pure
interpretation; reply, context objects and reported usage are then committed
before Kronos consumes the reply. An application can narrow the native host's
attempt ceiling through a pure frozen-profile callback; this dispatch check is
not applied to historical capture replay.

A lost process after dispatch without capture leaves unknown delivery. Neither
the native host nor the adapter silently retries it. Native restoration and
archive admission use original captures and their original request settings.

`P.AdaptiveResult` separates normalized result, replay reference/disposition,
and optional usage. Exact provider bytes remain a `CapturedResponse`, while the
adaptive context records the original prepared request and capture. The replay
grammar is closed, preserves call/result pairing and admitted phase/opaque
fields, and rejects provider-created tool additions. The aggregate reply limit
can return `normalization_limit` with retained usage and no replay, independently
of raw response and individual-field bounds.

The native grammar is checked against independent declarative fixtures,
including exact failure classifications, full-width integer arguments, Unicode,
opaque fields and ordered replay. The removed JS adaptive implementation is
superseded by scope change; no differential execution or dual-backend gate is
required. Existing v3/v4/fixed-profile v5 consumers retain their contracts.

## Bounds and observations

The example admits 1–16 charged model attempts, 0–16 control revisions,
14 approved skills, four active skills, 32 KiB per body, and 128 KiB of skill
bodies. Snapshot, bodies and catalog together fit the native 16 MiB frozen
resource ceiling. It retains at most eight evidence references, permits 12 work actions,
16 control receipts, and four answers/follow-ups combined. These are independent
ceilings, not a promise that every maximal field combination fits a request.

Provider requests are at most 256 KiB and responses at most 512 KiB. The
normalized adaptive reply is at most 16 KiB; its raw capture is retained on
projection overflow. Preparation checks the complete rendered request before
admitting a control. The reference has no handoff bundle or handoff-size gate.
Its message representation shares the transport's 256 KiB ceiling. Existing native
64 MiB requested allocation, 16 MiB worker and SQLite budgets, and 256 MiB
namespace limits remain unchanged. Protocol frames, checkpoint size, Kronos
working memory and namespace quotas remain separate limits.

External read-only qualification observations record actual byte counts, selection/epoch identities,
skill residency, D/O identities, marker positions, local visible-prefix equality,
returned model/context when supplied, optional usage, and bounded diagnostic
kind/reason/counts. Missing, null and zero usage are distinguished in the
observation report. Diagnostic counts are separate from billing usage and
cannot alter task success, trigger an extra request, or authorize a fallback.
No price or provider cache saving is inferred from fixture data or local bytes.

See the [acceptance map](adaptive-responses-acceptance.md) for executable proof
surfaces, artifact subjects and remaining qualification limits.
