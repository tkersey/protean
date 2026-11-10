# Workspace model-use evaluation

Live efficacy claims require executing this opt-in runner with explicit inference
authorization and adjudicating its results. Deterministic fixtures
establish available choices and runtime behavior; their scripted actions are not
evidence that a model independently discovered a useful computation or pivot.

## Recurring release investigations

The [2026-11-07 comparison](results/recurrence-2026-11-07.md) reports measured
correctness, resource use and unsuccessful discovery on one controlled workload
and configuration. Its accounting retains the infrastructure-invalid first
campaign and the separately authorized replacement campaign.

### Online answers from frozen sources

The separate `recurrence-online` suite makes intermediate answers useful before
the next selected request reaches the model. It retains the existing task owner,
question/answer protocol, workspace, grading oracle, interruption and accounting.
The original `recurrence` suite and its published final-only campaign keep their
original meaning.

```sh
node tools/evaluation/workspace.mjs prepare --suite recurrence-online \
  --config /private/operator-approved-adaptive.json \
  --binary zig-out/bin/protean \
  --driver zig-out/bin/protean-recurrence-driver \
  --application zig-out/protean/adaptive/application.json \
  --cost-model /private/deployment-tariff.json \
  --out /private/online-recurrence-campaign
```

Every immutable source record is present initially in the admitted snapshot's
`records.jsonl`. Later packets select requests by their exact target, revision,
scope, flags and record identities. Those future request descriptions are not
included in the initial snapshot or prompt. Packets provide source byte ranges
equally to both arms; the model still acquires those records through ordinary
snapshot access. These locations make this a computation and representation
comparison after lookup, not a test of finding documents. No future-document
withholding is claimed.

Both arms deliver each packet's supported answers through the existing `ask`
action, with this JSON object encoded as its `question` string:

```json
{"kind":"recurrence.answers.v1","packet_id":"selected packet identity","answers":[]}
```

The answer entries use the same fields and support rules as the final report.
The supervisor responds with the next due selection, or the existing queued-input
reminder, without revealing correctness. Native `input_required` events bind the
actual prompt, question identity, revision, request digest and event sequence.
Large question prompts use the ordinary task-scoped `artifact.read` route.
Repeated observation or an identical replay does not create another answer.

The private driver binds each pending question and accepted final report to its
own admitted controller model attempt and retains those bindings across
observation pages and restart. Source
coverage follows the producer's saved evidence and consumed workspace results,
including earlier `collect` and `wait` results and actual computation inputs.
Whole cited records must lie within acquired ranges of the exact frozen source
file. Source presentations retain their byte bounds; expanded values count only
source bytes recoverable from their observed JSON pages. Selected views count
only after native evidence establishes successful model exposure. Delegated
answers retain their actual input presentations and the source inputs at the
delegated port's historical computation cut. The final report's own
citations require acquisition before its producer, including records acquired
after the online answer when its final support changes.
Available but unconsumed work and asserted provenance do not establish
acquisition. Missing producer or acquisition observations remain unknown; they
cannot establish supported service or turn an independently known failure into
an unknown result.

The first answer must follow a successfully confirmed exposure of its own selection
and precede the earliest preparation that may have exposed the next selection.
The latter bound moves only when native evidence proves that an attempt was not
sent; a successful retry cannot erase an earlier uncertain delivery. Reports retain
separate exact decimal cuts for confirmed and possible exposure. Native event cuts
decide ordering; elapsed observations remain separate measurements. Merely guessing
selection bytes in model-produced text cannot create exposure: the selection must
also have its scheduled evaluator delivery and matching native admission event.
Duplicate or conflicting deliveries cannot replace an earlier answer. An earlier
unsupported ready or blocked conclusion remains critical after later correction.
All twelve answers must be sound online and in the final report before a positive
comparison can qualify. A final-only answer map does not satisfy this mode.

Existing deliveries also carry the remaining external wall allowance and the
task owner's `inference_observation`: `admitted_attempts`, `request_bytes` and
`known_output_tokens`. Decimal counters preserve their exact values. Request
bytes are not input tokens or prices; known output tokens are a lower bound, and
missing observations remain unknown. These additions create no separate model
turn. An unacknowledged delivery replays its original arguments and original
resource observation, rather than silently refreshing its message.

The treatment may construct and retain ordinary computation or descriptions.
The ordinary arm keeps continuing history and the same source access. Both use
the packaged controller; controller reconstruction and runtime replacement stay
disabled. Construction, a representation, or any specific solving method is never
required. This first online comparison does not test recursive controller
improvement.

An artifact reference in the final report cannot retroactively establish online
use. It must appear in the supported first online answer, and actual work or
selected-context use must follow the confirmed selection and precede that answer.
An artifact must already exist before the earliest possible later selection.
The original first eligible reuse
boundary, source/scope adjudication, SIGKILL, same-task reopen and later distinct
supported use remain required for a recovery claim. Ordinary direct answers can
succeed without a retained artifact.

The `ask` channel retains control history, including intermediate answers. That
input cost is included for both arms. Online reports retain exact prepared-request
byte profiles by field, tool and input item, using `request_profile.mjs`. Tools in
ChatGPT `additional_tools` input items have nested `tools` profiles; these refine
their enclosing item totals and are not additional top-level bytes. Those profiles
do not disclose payload text and do not estimate tokenization, caching or
monetary cost. The owner's request-byte counter measures admitted preparation
wrappers; the profiler separately measures the exact serialized provider body.
Preparation and offline fixtures establish mechanics only; live
efficacy requires separately authorized inference and adjudication. Use the same
`run` command below with the prepared online campaign directory.

### Original final-only delivery

The `recurrence` suite supplies one continuing task with twelve release-readiness
requests. Three frozen corpus instances each run once with an ordinary persistent
agent and once with construction and retention enabled. Order is treatment/control,
control/treatment, treatment/control. Controller reconstruction stays disabled;
both arms use the packaged application and runtime. Build/run gates disable those
capabilities in the ordinary arm; its other exclusions remain audited experimental
conditions, not security boundaries.

Build the private owner driver and run its offline boundary checks:

```sh
zig build recurrence-driver check-recurrence-driver -Doptimize=safe
node --test test/protean/recurrence.test.mjs test/protean/recurrence_delivery.test.mjs
```

The driver uses the actual adaptive environment, task owner, namespace and worker.
Its private NDJSON channel forwards ordinary task operations and explicitly asks
for one owner turn. It never pumps immediately after completing a worker. No
production protocol method or persistent artifact type is added. Both arms use
the same driver; only treatment requests the interruption.

Prepare the exact six attempts without provider calls:

```sh
node tools/evaluation/workspace.mjs prepare --suite recurrence \
  --config /private/operator-approved-adaptive.json \
  --binary zig-out/bin/protean \
  --driver zig-out/bin/protean-recurrence-driver \
  --application zig-out/protean/adaptive/application.json \
  --cost-model /private/deployment-tariff.json \
  --out /private/recurrence-campaign
```

Preparation freezes the realized packet bytes, arrival offsets, membership,
expected answers, oracle/evaluator source hashes, application/product/driver hashes,
profile, effort, limits and cost model. It refuses an existing campaign directory.
Each initial snapshot and task contains only the visible contract and first two
requests. Later raw documents stay outside snapshots, task inputs and tool input
catalogs until scheduled delivery. Generated documents are explicitly a controlled
audit workload, with exact immutable identities rather than production incidents.

The default schedule delivers the next ten requests at 180-second intervals and
END at 1980 seconds, under the original 2700-second wall deadline. The common
acceptance ceilings are 512,000 reported input plus output tokens, 128 physical
provider attempts, 1 GiB retained namespace storage and 4 GiB sampled RSS. The
wall watchdog stops execution. Other ceilings are assessed afterward; missing
usage and a sampled RSS observation do not establish hard native quotas.

There is one `task.submit` and one final answer map. A terminal report ends the
task; remaining requests are unanswered. A pending question can receive only a
predeclared factual answer or an already-due packet. The exact ordinary wait phrase
is part of the visible communication contract. Unknown substantive questions leave
the attempt incomplete. If inputs are already queued, the predefined response asks
the controller to consume them without duplicating their facts through the answer.
Operation IDs, chosen channels and complete RPC arguments are retained outside the
driver before sending; a lost acknowledgment retains the identical replay operation.

Start only with separately authorized inference and its selected source:

```sh
node tools/evaluation/workspace.mjs run \
  --plan /private/recurrence-campaign \
  --binary zig-out/bin/protean \
  --driver zig-out/bin/protean-recurrence-driver \
  --application zig-out/protean/adaptive/application.json \
  --authorize-inference --credential-file /private/credential-file
```

For ChatGPT plan inference, prepare with the ChatGPT configuration example and
replace `--credential-file` with `--chatgpt-account personal`. Optional
`--siwc-bin` and `--siwc-auth-dir` selections are forwarded unchanged on restart.
The two credential routes are mutually exclusive. SIWC uses the existing native
adapter; unknown plan or deployment charges remain unknown.

Each attempt gets a fresh namespace and is never overwritten or automatically
retried. Failures remain in the inclusive result. Restart during the declared cut
reopens the same namespace and task, retains operation identities, and continues
the original arrival clock and deadline. It does not submit another task, rebuild
the retained artifact or reacquire a captured response.

The first eligible mechanical reuse observation is retained permanently. For
programs it requires completed work on distinct canonical inputs across visibility
epochs, with the authored program already present. For descriptions it requires
the same authored value selected into completed model calls across epochs.
Computed values can be candidates when their native derivation identifies the
source-record program and completed work whose result they retain. One execution
followed by repeated selection of its result can therefore establish description
reuse; the retained value remains the artifact identity.
Public artifact content IDs are distinct from task custody IDs. Projected views
credit only the retained values actually rendered by their value, source or
computed blocks; projection dependencies alone do not establish exposure.
Prepared requests retain packet visibility evidence; successful captures confirm
delivery, including successful retries containing the same packet bytes. Confirmation
never moves the original exposure or preparation cut forward. Dispatch and capture
observations bound the visibility time rather than
pretending to observe the provider's internal clock. The cut seals ordinary owner
publication, requires no outstanding worker or uncertain acquisition, and stops
pumping before external SIGKILL. A first eligible return that already dispatched a
later request leaves the cut unestablished; it cannot be replaced with a favorable
later cut. The offline SIGKILL fixture proves custody, not model discovery.
Controller and delegated model preparations both retain their actual selected
views and feed the same description-use observations.
The supervisor owns every driver process group, including reopened and final-export
processes, and terminates local helpers on SIGINT, SIGTERM, normal exit, timeout
and close. This does not cover uncatchable supervisor termination or prove cancellation of inference
already received by a remote provider.

The independent oracle derives obligations and support from each request's raw
immutable evidence universe. The final report summary must be a complete JSON
object with an `answers` array, using the format given in the visible contract.
Correct status words alone earn no credit. Invalid entries and duplicate request
IDs lose credit independently; malformed outer JSON is never salvaged. False-ready
and unsupported-blocker claims are critical errors. Later documents do not resolve
an earlier request's missing or conflicting premises. Requests that never became
visible remain unanswered, even if an early report guesses their answers.
Comparison requires the report's exact frozen subject and plan digest, observed
END visibility, and terminal completion. Correct answers before END retain their
grading but cannot establish complete-stream payback. Legacy reports without
these bindings require explicit evidence review and receive no automatic credit.
Mismatched or duplicate reports retain their available expenditure separately;
they cannot establish positive or negative outcomes for the planned attempts.

`report.json` retains raw answers, grading, owner events, selected contexts,
program/value/work/input/result identities, physical attempts, usage, artifact
contents, scope-review slots and recovery evidence. `results.json` and `results.md`
include individual pairs, aggregate counts/costs, failures and cumulative expenditure
traces. Keep this directory private: captures and prepared requests are not public
release artifacts. Publish only deliberately selected, reviewed result material.
Archive totals and expenditure curves share the native occurrence classifier.
Known not-sent attempts leave provider expenditure when that evidence is observed;
earlier unknown usage and all preparation and elapsed costs remain visible.
Finalization retains completed captures before closing the driver and refreshes
committed attempt records after reopening. Final expenditure uses the archive's
physical-attempt inventory. Lost dispatch acknowledgments leave timing unknown;
missing inventory leaves counts unknown with observed lower bounds. Known token
subtotals above the ceiling establish an overrun even when missing usage leaves
the exact total unknown.

Source and trace adjudication remains necessary. `adjudicateRecurrence` binds that
review to the actual authored artifact hash and supported later answers. Review
the represented relationship, the observed repeated work, effective inputs, raw
record provenance, scope/invalidation and actual consumer use. Bind claimed authored
source to the model's actual build or materialization action; source format and
publication alone do not establish model authorship. Constant answers,
case-ID lookup, unused artifacts and stale scope cannot qualify. Selected context
establishes availability; supported output references strengthen observed use,
without proving causal necessity. Review judgments and their evidence stay in the
attempt report. A missing cut or post-restart use is a failed mechanism outcome,
not infrastructure uncertainty. The review must accept the exact two uses that
triggered the first cut and a distinct supported use after reopening. Favorable
later uses cannot replace an incidental or invalid original interruption trigger.

For monetary conclusions, a tariff file must contain `kind: "tariff"`, `id`,
`currency`, `predeclared: true`, `provider_source`, `deployment_source`,
`input_per_million`, `cached_input_per_million`, `output_per_million`,
`host_per_second`, `host_includes_attempt_storage: true`,
`storage_per_byte_second` and `retention_seconds`. Bind actual approved tariffs or
deployment charges, including any genuinely free components. Host time covers
startup through finalization and includes storage during execution; separate
storage pricing covers the declared subsequent retention period. Cache discounts
need the corresponding usage breakdown. Unknown charges never become zero. Omitting
the tariff allows preparation but leaves monetary efficacy undetermined.

All discovery, compilation, unsuccessful work, inference, fallback, maintenance,
interruption and finalization costs remain included. Compiler/publication intervals
are not added to elapsed time as though disjoint. One-time experiment engineering
and external adjudication are separate costs. The full positive milestone requires
at least one same-trace discovery/reuse/recovery witness with a cost-positive matched
comparison, plus lower summed treatment cost, at least as many sound answers and
zero treatment critical errors across all three pairs. An existence witness does
not establish reliability. A known failure of every same-pair conjunction disproves
the milestone; absent mechanisms do so even when monetary costs remain unknown.
Final answers arrive only at END, so an earlier
expenditure crossing cannot identify an earlier break-even request.

Prepare a comparison without making provider calls:

```sh
node tools/evaluation/workspace.mjs prepare \
  --config examples/adaptive/adaptive.example.json \
  --out /tmp/protean-evaluation --repetitions 3 --seconds 600
```

Use an admitted configuration with the intended endpoint, model and initial
effort. Preparation freezes that profile and effort, removes optional skills,
and creates three workloads: a direct configuration lookup, grouped GCDs over
256 rows, and a misleading ingestion hypothesis requiring broader evidence.
Each has ordinary, pure-program, and retained-workspace arms. Evidence and time
budgets match across arms; preparation records configuration, evidence, and expected-answer hashes.
The runner refuses changed inputs, unbound expected answers, and existing attempt
directories. Regenerate older plans that lack expected-answer hashes.

The arms are prompt ablations. Build/run grants disable construction in the
ordinary arm; the pure arm asks the controller to use only completed pure work.
It is not a separate runtime or a hard capability sandbox. Review recorded
actions and `arm_violations` before admitting a comparison. An arm violation is
an invalid comparison, not an improvement attributable to retained interaction.
Pure work permits terminal, owner-scheduled starts, waits and collection; pumping,
cut requests, realization changes and guest views violate that arm. Classification
and runtime-switch counts also interpret work commands inside `placement.control`.

After separately authorizing paid inference:

```sh
node tools/evaluation/workspace.mjs run \
  --plan /tmp/protean-evaluation --binary zig-out/bin/protean \
  --application zig-out/protean/adaptive/application.json \
  --authorize-inference --credential-file /private/credential-file
```

Runs are serial with separate namespaces. A question or time boundary stops
further work without inventing an answer. Each attempt retains its result,
archive, exact executable manifest, elapsed time, sampled peak RSS, namespace
bytes and metrics derived from actual occurrence/capture/work records. Private
captures remain private artifacts; do not publish the evaluation directory.
If an RPC, result read, process shutdown, or export fails, the runner saves the
attempt's identity, error, elapsed time and available observations before stopping.
Unavailable metrics and arm compliance remain null; reruns never overwrite or
automatically retry the attempt.

The report separates controller/delegated calls and tokens (missing usage stays
unknown), build/rejection counts, compiler nanoseconds, native publication
nanoseconds, checkpoint counts/current bytes, result bytes and prepared context
bytes. Native publication time includes execution and canonical checkpoint
projection; it excludes worker I/O and model latency. RSS is sampled, not an
allocator high-water mark. Retained namespace bytes include historical objects.
Call totals include unknown delivery and exclude positively unsent attempts,
including attempts superseded by an authorized rearm of the same occurrence.
Prepared context bytes still include those attempts because preparation occurred.
Malformed or non-JSON provider captures still count as calls with missing usage.
Only nonnegative safe integer token fields contribute known usage; partial usage
retains its known fields and also marks the call as having missing usage.
Action traces use the native normalized controller result. Raw function calls in
failed or rejected provider responses contribute no actions or arm violations;
their provider calls and available usage still contribute costs.

Adjudicate `task_correctness`, `evidence_coverage`, `successful_reframing`,
`unnecessary_construction`, and `branch_executions_not_used` against each frozen
`expected.json`, result, and action trace. Verify the expected file against the
report's `subject.expected_sha256` before adjudicating. These fields start null rather than
being guessed from termination. Record the evaluator's reasoning, including
failed or incomplete attempts. Compare all repetitions and all costs; no required
success rate, token reduction, minimum branch count, or mandatory construction
is built into the evaluation.

## Runtime discretion comparison

Prepare the executable-semantics comparison with the same runner:

```sh
node tools/evaluation/workspace.mjs prepare --suite runtime \
  --config examples/adaptive/adaptive.example.json \
  --out /tmp/protean-runtime-evaluation --repetitions 3 --seconds 600
```

The three arms are ordinary tools, retained computation under the packaged
generic runtime, and the full optional runtime/view interface. Each receives the
same evidence, model, effort and time budget. The families are a direct lookup,
eight different batches of dynamic GCD inputs that can reuse one program, and
the ingestion investigation whose answer requires broader scheduling evidence.
No prompt requires the model to specialize or to complete an analysis experiment.

The report counts requested specializations, realization switches and guest views
from accepted controller actions. It separately counts admitted runtime records,
distinct artifact bytes and distinct current capsule bytes from the archive.
Requests may be rejected; their count is not a count of successful operations.
Separate specialization/validation times remain null because the archive does
not measure those intervals; total elapsed time includes them. Adjudicate runtime
selection and economic benefit including setup against matched repetitions.
The generic-arm restrictions are prompt ablations with recorded violations,
not a new capability boundary. Use the same separately authorized `run` command
above. Preparing either suite makes zero provider calls; live efficacy remains
unmeasured until an authorized comparison is executed and adjudicated.

For deterministic costs and independent execution agreement:

```sh
zig build check-workspace-semantics -Doptimize=safe \
  -Dworkspace-wasm=/absolute/path/to/kosmos-kernel.wasm
```

This prints compiler arena/time, native time including process startup, WASM
time, checkpoint counts/bytes, and zero inference calls for the generated cases.
It reuses Horos's source oracle and Kosmos's retained embedding. These bounded
microbenchmarks do not predict end-to-end model efficiency.

## Reconstruction discretion comparison

Use the same runner with `prepare --suite reconstruction`. It prepares the same
three workload families with matched retained-workspace and reconstruction arms.
Only the latter enables `tools.reconstruct`; neither prompt requires a replacement
or a trial. The source/controller build and carry-conversion tools are ordinary
workspace actions. Preparation makes no provider calls.

The archive metrics count activated and rejected/aborted controller proposals,
trial work, and conversion publication time separately. Total compiler time,
inference costs, elapsed time and retained bytes still include unsuccessful
attempts. Judge task correctness, evidence coverage, unnecessary reconstruction
and recovery from misleading assumptions against the frozen expected answers.
Admission, successful activation and scripted demonstrations do not establish
improvement. Live efficacy is unmeasured until an authorized run is adjudicated.

## Semantic construction comparison

Prepare the semantic suite without provider calls:

```sh
node tools/evaluation/workspace.mjs prepare --suite semantic \
  --config /private/operator-approved-adaptive.json \
  --out /tmp/protean-semantic-evaluation --repetitions 3 --seconds 600
```

The suite freezes the same profile, effort, evidence, expected-answer hashes and
time allowance across three arms:

| Arm | Available approach |
|---|---|
| `specialization` | Ordinary tools, retained work and built-in specialization/runtime selection; no semantic source, programmable observations, interpretations, candidate construction or guard. |
| `interpretation` | Exact semantic source, programmable observations and isolated interpretations; no specialization, candidate derivation/validation, runtime replacement or guard. |
| `construction` | All operator-permitted source, observer, interpretation, transformer, validation, guard and qualified realization operations. |

The workload families are direct configuration lookup, eight distinct batches of
256 dynamic GCD inputs, and the misleading ingestion investigation. Construction
is optional: choosing ordinary tools, declining a transformation or abandoning a
candidate remains a valid model decision. Expected answers are retained for
adjudication, outside the model's snapshot evidence.

Preparation preserves the supplied `semantic_construction` policy; it never
approves a root or checker automatically. Configure exact installed roots and
checker identities, and enable `guard` only when comparison resources are
authorized. Missing approval remains a real denial in the run. The existing
`run --authorize-inference --credential-file ...` invocation is still required
separately. Arm restrictions are prompt ablations with recorded
`arm_violations`, not proof that arbitrary authored code stayed within a semantic
category. Review the actual code, inputs and actions when adjudicating them.

Metrics distinguish requested derivations, validations, guards and observers
from retained candidate artifacts and validated runtime facts. They record
distinct candidate code bytes, validated versus unvalidated retained candidates,
admitted runtimes, distinct runtime/capsule bytes and cumulative guard reference
and candidate nanoseconds. Guard costs are accumulated from publication history,
including replaced or discontinued guards. An unvalidated candidate count does
not distinguish a rejected candidate from one never submitted for validation;
inspect the action/result evidence for that distinction.

The existing compiler capture total, native publication time, model usage,
elapsed time, sampled RSS and retained bytes remain part of every comparison,
including unsuccessful attempts. Separate runtime specialization and validation
timing fields remain `null`; observer and interpretation costs are included in
ordinary work/publication totals rather than presented as independently measured
subtotals. Request counts are not success counts. Keep failed, interrupted and
abandoned candidates in the comparison and adjudicate correctness, coverage and
total cost against all matched repetitions. Preparing or inspecting this suite
does not establish live model efficacy.
