# Referenced provider context

`agent.model.invoke.v5` is an additive ordinary model effect in
`protean.model_invocation.Profile`. Existing v3 and inline-replay v4 formats and
consumers retain their exact meaning. The native fixed-profile product uses v5
because provider history must remain in immutable environmental storage rather
than grow inside the Kronos continuation.

`P.ReferenceRequest` contains the existing `P.Request` invocation, an optional
`ContextReference`, the existing bounded tool results, and a 32-byte frozen
profile digest. A null reference starts an empty history. It cannot recover
missing history. The authored program chooses the reference and supplies new
messages/results; an adapter cannot select another context by consulting a
mutable transcript.

`P.ReferenceResult` contains the existing normalized `P.Result`, an optional
successor reference, `ReplayStatus`, and optional usage. Raw capture, validated
replay and normalized action remain distinct. A complete continuation has a
reference to its immutable replay projection. Capacity or unsupported replay
cannot be treated as an accepted model action by the checked responder.

The reference binds SHA-256, byte count, schema identity, frozen profile digest,
16-byte task ID, tenant, audience, and the half-open item sequence range
`[first, next)`. The Responses core schema identity is
`agent.model.context.responses.v1`. These fields describe stored data; they
grant no read, inference or work-tool authority. The environmental owner must
check all bindings, current grants, bytes and complete dependency closure before
using a reference. A digest alone is not a capability.

The shared `ContextArtifact` is an ordinary encoded record containing those
subject/range bindings, a source-capture reference, an optional parent-context
reference and bounded JSON replay items. The digest covers the bindings as well
as the items. The native core checks the context/capture chain before use.

`protean.responders.defineReferenceModelObserved` uses the same checked responder
generator as v3/v4. It replaces the invocation's tools with the declarations
selected by the exact request-time offered set, preserves the supplied profile,
reference and results, and checks returned proposals against that retained set.
The authoring admission verifier classifies v5 as a protected model effect;
calling it directly or relabeling it as a read effect is rejected.

This contract does not provide a transport or prove artifact storage. The native
adapter and task owner must persist the exact acquired response before deriving
its replay and normalized views, and recover that derivation without another
network call. Native integration, provider corpus and backend qualification are
tracked by the single-binary implementation. There is no production JS v5
requirement or runtime dependency.
