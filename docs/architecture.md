# Protean architecture

The application emitter constructs one Horos source module. Protean checks its
catalogs and protected construction, then calls Horos's compiler once. Horos
owns type/effect/capture/use checking, direct stable-activation lowering, and
BPI3/PST3/ERQ3/ERS3/PKI3/PKO3. Kosmos owns execution. The native source lock
selects an explicit development successor tuple for Horos and Kosmos.
Published 3.0.0 / 6.0.0 artifacts retain their original identities. The adaptive
agent is the supported application; reusable authoring and native-host owners remain.

| Owner | Responsibility |
|---|---|
| Application | Control topology, declared policies, data retention and context projection |
| Protean | Typed domain constructions, semantic contracts, protected source admission |
| Horos | Source calculus, portable values, checking, compilation and pure codecs |
| Kosmos | Program-relative state admission, interpretation, protocol framing and binding |
| Environment | Faithful typed results, credentials, authentication, atomic external operations |

`protean.system` binds InitialArgs, Result, Failure, optional descriptor catalogs and
an application emitter. `protean.compile` owns its temporary Builder/catalog/registry
storage; returned Horos Construction output owns independent storage. There is no
runtime callback registry, Protean control IR, compiler-selected application body,
or executable policy sidecar. The adaptive application authors its own loop.

The model responder captures the exact request-time offer set and selection policy,
constructs declarations from the closed catalog, and checks every returned claim.
The adapter preserves normalized items; the image owns candidate admission.

Internal dialogue packages own their futures. The surrounding program may retain,
resume, route, or dispose a child while serving another request. Only the complete
PST3 is portable execution state. A nested turn returns to its caller; only root
termination completes a conversation. Lexical Reader/state/region constructions
retain scopes across suspension and restore enclosing interpretations on exit.

Horos owns internal multi-shot resumption and region semantics. Protean checks
effect roles through bodies, handlers,
computation origins, forwarded capabilities, cleanup and successor handlers.
Approval, writes, commits, live-evidence acquisition and unclassified effects cannot
enter speculation. Higher-order admission conservatively checks every source
lambda sharing a computation schema. When unrelated code shares that schema,
`protean.callable.define(builder, function, signature)` gives the static function
identity its own ordinary Horos computation schema; `protean.callable.value`
produces its lambda. Repeated definitions of the same function and signature
share that declaration. The helper asserts no safety: actual bodies, residual
rows and captures still pass the same final admission. Original structurally
interned source may remain conservatively rejected; the helper is a public source
composition with unchanged runtime semantics, not a new execution rule.

Protected admission scans actual source, including alternative entry/handler edges,
instead of trusting a list of helper names. Native application authors choose policy
and are trusted not to mutate Builder internals or forge admission metadata. Raw
Horos authoring without the same Protean gate carries no protected-system claim.

The native host delegates to Kosmos and returns original canonical outcomes. Inspection
is a non-authoritative view. Missing input stays parked; cleanup can itself park.
Killing an execution worker produces no authoritative successor or cleanup proof.
Content identity, conversation identity and delivery occurrence are distinct; whole
snapshot copies can replay prior control and require environmental safeguards.

## Adaptive computational workspace

The effective root is a task-owned controller binding. The packaged seed and
source-built successors share the protected controller constructor. Pure carry
conversion and inert boot precede an atomic authority transition; retired roots
retain their original cleanup obligations. Same-site behavior and cross-site
movement extend the same authority lineage. See the
[controller contract](computational-workspace.md#reconstructing-the-active-controller).

The adaptive application 7 controller chooses `program`, `work`, and `context`
actions through the same captured offer/admission path as ordinary tools. It can
finish without using them. A child's input type constrains a supplied answer;
it does not constrain the next controller action. Neither status nor uncertainty
automatically invokes a model or chooses an investigative method.

`source_records.zig` reflects the linked Horos `source.Module` as versioned data.
`source_preflight.zig` validates transport indices and structural dependencies
before ordinary Horos checking/lowering. `program_construction.zig` rejects raw
protected/external declarations and builds ordinary BPI3. Existing component
recipes still use the frozen pure linker. `workspace_driver.zig` constructs
ordinary source handlers and packages for exposed ports; typed futures remain
inside the whole program state. Alternative ports use admitted multi-shot
resumptions. Exposure metadata alone cannot manufacture a reusable capability.

The existing Service schedules task roots, child work and retired-controller
residuals through one queue and one occurrence engine. Their occurrences bind different subjects even
when their request bytes match. Each child owns its exact program, typed input,
Kosmos checkpoint, execution/control revisions, scheduling policy, and observed
outcome. Immutable content identities do not confer task custody. No second
evaluator or host-side program-control language interprets these records.

Only the Service commits Programs, Work, ports, values, views, routes, and
operation receipts. It freezes compiler inputs before dispatching the existing
worker and publishes code only after capture and checked interpretation. The
worker has no Store or Resident. Lost compiler work is definitely not sent;
ambiguous environmental work remains unknown. Root completion parks unused
automatic work, and pending cleanup or delivery remains discoverable.

Explicit interpretation delegations create ordinary single-effect instrument
programs bound to a real target port, profile/snapshot, input references, and
current authority. The registry marks these handlers as workspace-only so root
manifest completeness remains exact. A child model answer is typed evidence;
it is not a replacement controller or a new grant. Pure programs invoke no model.

Runtime-schema projection shares canonical scalar/value rules and Horos
descriptors. Views retain source and hypothesis ancestry, coverage, and broader
authorized access. Selecting a view creates a context epoch for future requests;
policy, user messages, active skills, and current action availability survive.
An in-flight request and historical evidence are immutable.
