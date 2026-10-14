# Native Responses core

`protean_native.adaptive_responses.Adapter(Profile)` implements the sole
`agent.model.invoke.v11` contract. `Profile` is
`protean.model_invocation.Profile`; `declare` and `defineModelObserved` construct
the checked model boundary. Native code renders requests and returns proposed
values; the authored responder retains call selection and authorization.

The frozen task profile contains the approved adaptive policy, inference
profiles, and skill catalog described in the [v11 contract](model-invocation-v11.md).
The request binds its policy digest, selected profile, materialized definitions,
offered calls, and context plan. Credential bytes are supplied separately through
`responses.Environment`, together with the explicitly approved endpoint; they
never enter the rendered body, checkpoint, profile, or capture. HTTPS uses system
trust or an explicitly supplied DER trust root. Credential discovery, redirects,
and automatic retries are absent. Transport bounds and deadlines are optional
caller-selected physical policies.

The core sends foreground, nonstreaming, `store: false` requests with truncation
disabled and `parallel_tool_calls: false`. It admits at most one function call
per response and rejects the whole batch otherwise. It does not use provider
conversation IDs or `previous_response_id`.

Context v6 stores immutable history chunks and roots with exact prepared-request
and capture ancestry. References bind the object, schema, policy, selection,
task, tenant, audience, epoch, watermark, and eviction generation. Owned
projection checks the complete closure before reusing validation within its
integrity epoch; generic readers validate on each projection. Every outstanding
call requires its original result before continuing. Missing context rejects
rather than triggering fresh inference.

Supported replay items are text messages, completed function calls/results,
assistant messages with supported phase values, and reasoning items containing
opaque encrypted continuation data. Unknown material fields, hosted tools,
annotations with unimplemented semantics and missing opaque reasoning produce
an explicit limitation. The response envelope is not replayed. Duplicate keys
and invalid Unicode reject; integer lexemes are retained without floating-point
conversion. Refusal, incomplete/provider failure, unsupported material and
capacity are distinct from an accepted application report.

The task owner writes the prepared request and charges the physical attempt
before I/O. It commits the exact response body plus HTTP status and returned
request ID before interpretation. Interpretation is a separate pure transition
which atomically stores the typed result and immutable replay object. A restart
reuses the raw capture; it cannot call the transport again for that occurrence.
Returned usage preserves absent counters, including absent versus zero cached
tokens, and successful interpretation updates the task's output-token total.

The versioned independent corpus is
[`native-responses-v1.json`](../test/protean/native-responses-v1.json). It includes
reasoning/phase, exact integers, refusal, duplicate keys, invalid Unicode,
missing call IDs, invalid batches, malformed arguments, unsupported output and
incomplete responses. Native tests compare complete normalized bytes against
fixed expectations from the previously checked shared v3/native corpus. The
retired JS normalizer is no longer executed or shipped. Native whole-batch,
Unicode and missing-call-ID behavior retain explicit independent expectations.
The controlled HTTPS peer checks chain, hostname and expiry rejection, response
size and truncation, deadlines, exact bodies and no retries/redirects.
[Protean](../examples/adaptive/README.md) uses the native v11 adapter
and the same capture, recovery and transport owners. Current exact-head proof
surfaces are listed in the [acceptance map](adaptive-responses-acceptance.md).
Live inference requires separate authorization and is not claimed here.

The projection follows the official
[conversation-state guide](https://developers.openai.com/api/docs/guides/conversation-state),
[reasoning guide](https://developers.openai.com/api/docs/guides/reasoning), and
[Responses request contract](https://developers.openai.com/api/reference/resources/responses/methods/create).
