# Native Responses core

`protean_native.responses.Adapter(Profile)` implements the shared
`agent.model.invoke.v5` contract. `Profile` is the existing
`protean.model_invocation.Profile`, including its derived argument codecs and
checked responder. Native code renders requests and returns proposed values;
the authored responder retains tool selection and authorization.

The enclosing frozen task profile contains a closed `responses` object:

```json
{
  "responses": {
    "endpoint": "https://api.openai.com/v1/responses",
    "audience": "openai",
    "model": "EXPLICIT_APPROVED_MODEL",
    "effort": "medium",
    "max_output_tokens": 4096,
    "request_bytes": 262144,
    "response_bytes": 524288,
    "timeout_ms": 30000
  }
}
```

This illustrates the schema, not a selected or authorized live profile. Admission
must choose a supported model and freeze the complete non-secret task profile.
The invocation's profile digest, model, reasoning effort, response limits,
declarations and codecs must match. Credential bytes are supplied separately
through `responses.Environment`, together with the explicitly approved endpoint;
they never enter the rendered body, checkpoint, profile or capture. The HTTPS
transport uses system trust or an explicitly supplied DER trust root. No
environment-variable credential discovery, proxy discovery, redirects or retry
occurs. Each call has finite request/response limits and a cancellation deadline.

The core sends foreground, nonstreaming, `store: false` requests with truncation
disabled and `parallel_tool_calls: false`. It admits at most one function call
per response and rejects the whole batch otherwise. It does not use provider
conversation IDs or `previous_response_id`.

Context objects use the shared ordinary `ContextArtifact` codec and contain the
ordered JSON input-compatible items, their source capture and prior context.
Their immutable payload repeats the subject bindings, so relabeling a reference
cannot reassign another task's history. References bind
their digest, length, schema, frozen profile, task, tenant, audience and half-open
item range. The core resolves and checks those bindings and the bounded chain's
capture/context closure before rendering. Every
outstanding call requires one result with its original call ID before new
messages enter the next request. Missing context cannot trigger fresh inference.

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
[Protean](../examples/adaptive/README.md) uses the native v6 adapter
and the same capture, recovery and transport owners. Current exact-head proof
surfaces are listed in the [acceptance map](adaptive-responses-acceptance.md).
Live inference requires separate authorization and is not claimed here.

The projection follows the official
[conversation-state guide](https://developers.openai.com/api/docs/guides/conversation-state),
[reasoning guide](https://developers.openai.com/api/docs/guides/reasoning), and
[Responses request contract](https://developers.openai.com/api/reference/resources/responses/methods/create).
