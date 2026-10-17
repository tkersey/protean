# Workspace model-use evaluation

Live efficacy is unmeasured until this opt-in runner is executed with explicit
inference authorization and its results are adjudicated. Deterministic fixtures
establish available choices and runtime behavior; their scripted actions are not
evidence that a model independently discovered a useful computation or pivot.

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
