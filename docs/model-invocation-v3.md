# Protean model invocation v3

`agent.model.invoke.v3` is an ordinary external Horos 2 effect. Its payload
and result are application-specific schemas derived by `model_invocation.Profile`.
Its provider protocol remains `agent.model.protocol.openai-responses-v2`.
The image selects model configuration, semantic messages, offered declarations,
normalization bounds and answer policy. These schema and authoring contracts
remain shared by the native v5/v6 adapters. The former JavaScript v3 transport
is retired; the native application uses v6.

Use `Profile(Answer, declarations, limits)` for a tagged answer union and one
name/description per variant. Each payload is an enum or a flat product of bounded
Text, bool, i8/i16/i32/i64, u8/u16/u32/u64 and exhaustive enums with u32 tags.
`Question(Value, name, description, limits)` derives one synthetic `answer`
declaration. Product and enum values are its payload directly; other admitted
scalars use a product field named `value`. This declaration has no tool
implementation or commit authority. Unsupported codecs reject during authoring.

`P.declare(builder)` shares one effect for an identical schema specialization.
`P.allDeclarations()` returns type-owned immutable schema/codec metadata.
`P.declarationsValue(allocator, offered)` returns a caller-owned selection slice;
its nested immutable metadata is shared. `P.invocationValue` is an authoring
convenience for constant requests. Runtime context and message construction use
ordinary Horos product/vector/blob terms with the same schemas.

The checked `responders` model path uses `P.templateValue(Model, messages,
selection)` for configuration without a duplicate tool catalog. It regenerates
the actual request's declarations from the same offered set retained across
suspension and supplied to answer admission. The generated invocation does not
return approval or execute a proposed operation.

Final Protean source admission requires model emission to occur at that checked
responder's owned site. A direct `perform` followed by a caller-selected offered
set cannot claim protected Protean custody. Custom Ask interpretations call the
same checked responder; independently authored raw Horos programs remain
possible through Horos's compiler without that Protean claim.

`responders.defineModelObserved(P, context, failure, batch)` and
`responders.invokeModelObserved(...)` retain the complete result as
`ModelObservation(P, batch) { normalized: P.Result, interpretation: ... }`.
Applications can inspect exact transport/provider failure kinds, refusal text,
call IDs, raw arguments and other normalized output when authoring recovery or
memory policy. The normalized field remains untrusted provenance even when the
adjacent interpretation rejects it. It is not an operation or approval token.
The candidate-only convenience calls this same checked owner and projects its
interpretation; it does not perform another model call or normalize again.

## Wire order

Values use Horos 2's documented encoding: minimal unsigned LEB128 lengths and
sum ordinals; fixed little-endian scalar integers and explicit u32 enumeration
tags; ordered products; UTF-8 text. No BPI1 envelope is accepted as v3.

| Product | Fields, in order |
| --- | --- |
| Request | protocol, model, parameters, messages, tools, selection, response_policy, normalization_limits, maximum_provider_response_bytes |
| Parameters | max_output_tokens?, temperature?, reasoning? |
| Reasoning | effort?, summary? |
| Message | role, content |
| Tool declaration | action_ordinal, action_tag, name, description, input_schema_json, strict, argument_codec |
| Codec field | name, kind, bit_width, maximum_bytes, enum_names, enum_tags |
| Selection | minimum_calls, maximum_calls, parallel_calls |
| Response policy | store, stream, background, truncation |
| Normalization limits | maximum_output_items, maximum_call_id_bytes, maximum_name_bytes, maximum_arguments_bytes, maximum_argument_name_bytes, maximum_argument_fields, maximum_result_text_bytes |
| Function call | call_id, name, arguments_json, tool_ordinal_claim, decoded_action |
| Output | items, normalized_output_digest |
| Provider failure | kind, http_status |

`Result` sum order is `output`, `refusal`, `transport_failure`,
`provider_failure`, `unsupported_response`. Output-item sum order is
`function_call`, `message`, `reasoning`; a reasoning item contains `summary`.
Decoded-answer sum order is `decoded(Answer)`, `invalid(DecodeFailure)`.
`Answer` sum ordinal follows its declaration order even when the Zig union tag
has another numeric value. `action_tag` retains that logical value as metadata;
it is not a wire sum ordinal. Optional values use `0 = absent`, `1 = present`.

Enum order is fixed by these declarations:

- Role: system, developer, user, assistant.
- Codec kind: text, signed_integer, unsigned_integer, boolean, enumeration.
- Decode failure: malformed, duplicate_field, unknown_field, missing_field,
  wrong_type, integer_range, capacity.
- Transport failure: unavailable, denied, interrupted, response_too_large.
- Provider failure: http_status, response_failed, response_incomplete.
- Unsupported response: unsupported_protocol, unsupported_parameter,
  malformed_json, invalid_utf8, unsupported_status, unsupported_output_item,
  mixed_refusal, normalization_limit.
- Reasoning effort: none, minimal, low, medium, high, xhigh, max.
- Reasoning summary: auto, concise, detailed. Truncation: disabled.

`P.Request`, `P.Result` and all nested public types are the concrete contract.
ERQ2 embeds their canonical schemas and contract binding. Descriptor limits are
explicit application representation choices, not Protean lifetime limits.

## Candidate admission and trust

`P.interpretAll(builder)` builds an ordinary source function accepting
`(P.Result, [declaration_count]bool, Selection)` and returning
`P.BatchInterpretation = accepted([]Answer) | rejected(InterpretationFailure)`.
It checks every call's name, declaration ordinal, decoded typed variant and
request-time offered set, enforces minimum/maximum/parallel policy, and preserves
candidate order. Non-call normalized items remain present in the original result.
The returned sequence cannot outgrow the declared incoming output-item bound.

`P.interpreter(builder)` provides a single-answer specialization returning
`accepted(Answer) | rejected(InterpretationFailure)`. It requires a single-call
selection policy and rejects additional calls rather than choosing one. Both
specializations are emitted from the same admission implementation.

Capture the offered set and selection with the request continuation. Supplying a
new current offer set to the interpreter is not request-time custody. The
enclosing application still rechecks current policy and preconditions before
dispatch; accepted candidates are ordinary data, not approval.

The adapter preserves every admitted call ID, name, raw argument JSON and decoded
claim. Integer decoding retains exact 64-bit values, including exponential JSON
number spellings. It rejects duplicate/unknown/missing fields, unsupported value
shapes, invalid Unicode and bounded-value violations. Decimal model parameters
are transported without binary floating-point conversion. The normalized digest
is SHA-256 of canonical encoded output items and is diagnostic consistency data.
It does not prove truthful provider I/O or honest argument decoding.

`performModelInvocation(payload, options)` accepts only endpoint, apiKey and
signal options. Credentialed requests are restricted to the exact supported
provider endpoint; uncredentialed loopback HTTP is available for tests. No model
inference is retried. There is no default deadline. Supplying `signal` chooses an
embedding-owned operational deadline; expiry yields typed `interrupted`, and is
neither authored cancellation nor root completion.
The standard profile requests normalized nonstreaming output.
The built-in adapter returns `unsupported_parameter` before provider I/O when
`stream` or `background` is true. It does not silently rewrite either policy.

Model results do not authenticate human identities, prove real observations,
authorize writes or provide exactly-once delivery. Approval, simulation provenance
and environmental operation authority remain separate authored contracts.
