# Protean 4 architecture

The application emitter constructs one Horos source module. Protean checks its
catalogs and protected construction, then calls Horos's compiler once. Horos
owns type/effect/capture/use checking, direct stable-activation lowering, and
BPI3/PST3/ERQ3/ERS3/PKI3/PKO3. Kronos owns execution. The native source lock
selects an explicit development successor tuple for Horos and Kronos.
Published 3.0.0 / 6.0.0 artifacts retain their original identities. The adaptive
agent is the supported application; reusable authoring and native-host owners remain.

| Owner | Responsibility |
|---|---|
| Application | Control topology, declared policies, data retention and context projection |
| Protean | Typed domain constructions, semantic contracts, protected source admission |
| Horos | Source calculus, portable values, checking, compilation and pure codecs |
| Kronos | Program-relative state admission, interpretation, protocol framing and binding |
| Environment | Faithful typed results, credentials, authentication, atomic external operations |

`protean.system` binds InitialArgs, Result, Failure, optional descriptor catalogs and
an application emitter. `protean.compile` owns its temporary Builder/catalog/registry
storage; returned Horos Construction output owns independent storage. There is no
runtime callback registry, Protean control IR, compiler-selected application body,
or executable policy sidecar. ReAct is an ordinary library composition.

`Ask<Q,A>` is an internal typed demand. Its staged responder may ask a human, invoke
a model, compute a rule, or call another authored body. The same continuation
resumes at its call site. Answers do not become authority by their origin label.
The model responder captures the exact request-time offer set and selection policy,
constructs declarations from the closed catalog, and checks every returned claim.
The adapter preserves normalized items; the image owns candidate admission.

Internal dialogue packages own their futures. The surrounding program may retain,
resume, route, or dispose a child while serving another request. Only the complete
PST3 is portable execution state. A nested turn returns to its caller; only root
termination completes a conversation. Lexical Reader/state/region constructions
retain scopes across suspension and restore enclosing interpretations on exit.

Deliberation uses internal multi-shot resumption. Only immutable evidence crosses
into branch evaluation; captured mutable branch state follows Horos's region
semantics. Protean additionally checks effect roles through bodies, handlers,
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

Live and simulation domain clients share a typed interface with distinct
observations. Only the corresponding live read owner can mint the private evidence
required by a live-precondition approval. Data can inform speculative assessment;
its authority remains outside the captured continuation.

`approve_and_commit` retains the exact proposal and authority occurrence, checks
structural equality, authenticating-adapter principal scope, current policy and
required live evidence, then consumes its internal grant before the sole commit
request. Amendment needs another occurrence and decision. Uncertain delivery is
returned for explicit reconciliation, never automatic replay. External operations
atomically enforce their final preconditions.

Protected admission scans actual source, including alternative entry/handler edges,
instead of trusting a list of helper names. Native application authors choose policy
and are trusted not to mutate Builder internals or forge admission metadata. Raw
Horos authoring without the same Protean gate carries no protected-system claim.

The native host delegates to Kronos and returns original canonical outcomes. Inspection
is a non-authoritative view. Missing input stays parked; cleanup can itself park.
Killing an execution worker produces no authoritative successor or cleanup proof.
Content identity, conversation identity and delivery occurrence are distinct; whole
snapshot copies can replay prior control and require environmental safeguards.
