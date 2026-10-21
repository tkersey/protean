# Model-directed semantic construction

This local implementation extends exact semantic-source inspection, authorized
observations, isolated interpretations, and generated runtime construction through
the existing workspace owners. The public contract is
[Computational workspace](computational-workspace.md).

Qualification remains incomplete. Required Linux qualification runs on native
Ubuntu x86-64 GitHub Actions runners with Zig 0.17.0. The deployment harness
retains execution tracing and Bubblewrap user, mount, and PID namespaces.
Local Rosetta probes do not substitute for those checks. Full product checks
and the workflow's 600-second aggregate gate remain outstanding. The library
feature branches are published for GitHub qualification. No deployment, paid
inference, or claim of autonomous model improvement accompanies this implementation.

## Construction and authority

`program.inspect` and `context.materialize` expose the actual selected semantic
source and explicitly authorized state. Structural schemas retain their
program-relative IDs. Complete reconstructible snapshots require complete guest
disclosure; partial views retain their omissions and provenance.

Observer subscriptions schedule ordinary pure work and commit outputs with their
cursor. Isolated interpretation supports alternative assumed replies and retained
unfinished branches. Neither route acquires a real external response.

The generated producer runs as ordinary Horos source over the disclosed source.
It returns candidate source and finite relation evidence; the native compiler
does not replace its output. The independent checker admits its supported scalar,
closed-helper, relocation, specialization, and private product-layout relations.
Unsupported relations and exhausted checks cannot approve a candidate.

Optional source materialization includes a digest-bound reverse-reference index.
The host enumerates source references; ordinary generated code selects and edits
the affected declarations. Default materialization does not build the index.
Validation reconstructs the relation independently from the complete source.
A same-schema missing-reference mutation remains well typed and is rejected by
that checker.

Checked realization changes preserve retained guest state. Reference guards
compare canonical successor state, observation, and guest work before the
reference owner publishes effects. Agreement is finite evidence, not a proof of
arbitrary candidate equivalence. Existing reply custody and cancellation own
settlement and cleanup. Active guards and observer subscriptions must be removed
before the unsupported mobility cases.

Import and placement freeze prepare exact compiler facts from immutable inputs
before opening their Store transaction. Retained semantic-source reads and values
also prepare their exact rendering, including source slicing. The transaction
still checks current policy, provenance, custody, and history; a missing prepared
compiler result rejects before compilation.

Context materialization and selection prepare only their selected dependencies.
Descriptor lookup filters declared metadata before validating a matching owner.
Unrelated semantic-source values cannot trigger compiler work during lookup.
Scoped facts survive response projection and restore any enclosing facts afterward.

The implementation rebases onto accepted controller reconstruction
`2e40ce45d0f4b9b2ee81838386d5f1e0693ea228`. Package/host 7.0.0, application 8.0.0,
workspace contract 4, and native state format 18 retain historical executable
bindings; they do not migrate old state implicitly. Horos is 6.1.0 and Kosmos is 9.1.0. The
[dependency lock](../conformance/protean/dependencies.lock.json) records exact
source commits and archive identities. Downloaded GitHub archives match the
complete committed source inventories; the Linux native setup still independently
authenticates transport and extracted content during qualification.

## Coverage and measurement scope

Existing source, runtime, workspace, and placement roots contain the acceptance
discriminators. The shared witness covers disclosure and partial expansion,
observer gaps and replay, alternative interpretation, generated source/layout
changes, independent negative mutants, retained activation, finite guard
divergence, cancellation, and peer transfer. The second producer invocation uses
the first candidate's source and exercises the same generated program.

The five execution arms are generic, built-in specialized, generated validated,
instrumented, and reference guarded. They start at the same retained request and
measure three matching cuts. Construction and validation are separate from
continuation, publication, and inspection. Logical artifact/reference byte counts
are not deduplicated disk footprint. Requested memory remains unmeasured where
the output says so. No break-even or universal speedup follows from these finite
measurements.

The [evaluation runner](../tools/evaluation/README.md) supplies matched real-model
comparison conditions and retains unsuccessful work. Its semantic preflight
prepares nine cases without inference. Independent model discovery and efficacy
remain unmeasured.

## Footprint

The comparison bases are Horos `ae8ace5`, Kosmos `6c70d24`, and accepted Protean
`2e40ce4`. This table counts added and deleted source lines, including newlines,
in dedicated test files and inline test blocks, rather than net file-size change.
It excludes test-only helpers outside those blocks and is therefore a partial
measure of test implementation size.

| Repository | Changed test files | Added bytes | Deleted bytes |
|---|---:|---:|---:|
| Horos | 11 | 66,537 | 112 |
| Kosmos | 8 | 76,883 | 773 |
| Protean | 19 | 197,443 | 18,064 |
| Total | 38 | 340,863 | 18,949 |

The count includes inline test blocks and existing test-root imports in Horos
and Protean production modules.

The complete changed Zig source, including production code and all test helpers,
adds/deletes 296,472/61,105 bytes in Horos, 231,040/16,904 bytes in Kosmos, and
488,814/57,547 bytes in Protean. These totals expose helper code omitted by the
test-block breakdown; they do not attribute all source growth to tests.

No test modules, directories, executables, or CI lanes were added. Protean's
existing workspace execution count advances from 12 to 14. The largest extension
is `workspace_runtime.zig` at 152,627 added bytes; the low module count does not
make this a small fixture change. Its generated producer and candidate are reused
by the custody, five-arm, and mobility checks, avoiding a third producer run.
Historical independent byte fixtures remain unchanged.

Copied-custody forgeries run in the existing onward-transfer scenario with its
smaller guest. Their assertions exercise common import normalization and custody
gates. The generated scenario retains exact artifact closure, disclosure and
semantic-trust rejection, signed acceptance, replay, restart, and cleanup.
Construction and guard helpers finish their temporary work before the mobility
scenario begins, with terminal cancellation and disposal assertions.

The packaged semantic core is 234,530 bytes, SHA-256
`a52cb0f18b69a8884bbe93ab2c5d75d7c7a6aa3d8883d21f2d473ab616c14c10`.
Generated candidates use `kosmos.semantic-artifact/3` and
`kosmos.source-relation/1`; the existing artifact family remains `/2`.

## Qualification results

Commands use exact Zig 0.17.0 and Safe optimization on Apple silicon. Cold means
fresh local and global compilation caches with authenticated dependency source
packages available; warm reuses those caches and still executes the checks.
Times measure the build/check commands, including compilation. They do not
measure the Linux workflow's setup, archive transport, or aggregate elapsed gate.
Every command has a 600-second watchdog.

Qualification now reuses matching artifacts under the existing input-aware cache
key and rebuilds on a miss. Selected tests always execute. Earlier cold and warm
measurements describe their original inputs; further paired runs are not required.
Protean's latest custody qualification uses commit `1d3885a9` with Horos
`a97e41aa` and Kosmos `67d0b71c`. The other native results below precede the
context-preparation repair and require qualification against the final tuple.
Commit `bcfca656` restores the original Linux deployment assertions.

| Historical tree and command | Cold seconds | Warm seconds | Result |
|---|---:|---:|---|
| Horos `816d2d8`, `check check-package` | 198.309 | 105.816 | 266/266 steps, 932/932 tests |
| Kosmos `acf8d71`, `check` | 527.043 | 340.761 | 69/69 steps, 329/329 tests |

| Library tree and command | Seconds | Result |
|---|---:|---|
| Horos `a0b0b256`, `check check-package` | 144.568 | 266/266 steps, 957/957 tests |
| Kosmos `814aa999`, `check` | 471.775 | 69/69 steps, 329/329 tests |

Horos's committed TigerStyle audit passes all 322 files and 123,157 lines with
zero diagnostics and 34 auditor tests. Kosmos's committed ratchet passes 35
changed files and 5,789 changed lines with zero diagnostics and 24 auditor tests.
The largest individual compiler RSS reported by the current Horos and Kosmos
checks is `3G` and `4G` respectively in the build summary's rounded units;
neither is aggregate concurrent memory. Horos reports 60 successful compiler
steps. Kosmos reports 12 successful compiler steps.
Kosmos's full check includes 9,570 independent source-agreement observations,
Chromium and Firefox worker transfer, and extracted package operation.

Horos `893b964a` passed those checks but its completed review epoch accepted
allocation-budget, validation-work, and raw-constructor preservation findings.
Successor `cd256c1d` passes full native, WASM and package qualification. Decoded ownership
now shares one allocation budget; source emission and mandatory target admission
share the relation's work allowance, before optional optimization. Constructor
bindings retain the actual function, schema, and ordered capture origins.
Relocation transports raw constructor indices, and pure slices generate ordinary
registration helpers when the original registration function is pruned.
Focused native tests cover identity and permuted relocation, scalar rebinding
rejection, supplied capture ordering, bridge removal, and allocation failure.
Full Kosmos integration against the preceding Horos commit exposed an
admission charge incorrectly consuming the specialization-local work allowance.
The repair separates that allowance from the relation-wide budget. Focused scalar
and actual generic specialization pass with the unchanged 8-million local and
64-million relation limits. The actual generic record requires 2,046,542 bytes of
owned allocations: the previously ineffective 1-million-byte test allowance now
rejects, and the existing production 64-million-byte allowance passes.

Fresh Horos review remains outstanding. Historical Kosmos `8392e18a` packages the
preceding Horos source; regeneration passes 7/7 steps in 81.266 seconds. Its full check
finishes in 473.606 seconds with 327/329 tests passing. The two driver failures
exhaust the relation budget in composed transformations; all 28 specialization
tests and foreign checks pass. A focused trace attributes 9,608,508 work units
per generic admission to repeatedly clearing and scanning the entire block catalog
for function-local borrow queries, plus 1,170,924 units to requirement lookup.
Horos `a0b0b256` indexes blocks by owning function and requirement rows by their
exact entry/position key. Focused ownership tests pass 32/32, including allocation
failures, retry, interleaved function blocks, and retained reachability snapshots.
Both previously failing Kosmos drivers pass with the unchanged relation limits.
On the same generic source, mandatory admission falls from 13,049,598 to
2,317,832 charged work units, an 82.24% reduction. The focused integration run
passes 5/5 tests in 123.439 seconds, including the scratch measurement. Full
Horos qualification passes 266/266 steps and 957/957 tests in 144.568 seconds;
the committed style audit passes.
Kosmos `814aa999` packages Horos `a0b0b256`; artifact regeneration passes 7/7
steps in 80.998 seconds. Full qualification passes 69/69 steps and 329/329 tests
in 471.775 seconds, including all 39 driver and 28 specialization tests. Its
committed style audit also passes.
Protean now resolves raw closures to their actual function during private
and speculative authority checks. Its constructor-preservation and executable
pure-slice changes are committed in `4773f20c`; the dependency lock now selects
Horos `a0b0b256` and Kosmos `814aa999`. Commit `298cb97` includes the fourteenth
execution test in CI. Final
native integration tests, product checks and Linux qualification remain
outstanding; library checks do not establish them.

Protean's prior native checks at `6d1b7064`, before the context repair, are:

| Existing qualification root | Seconds | Result |
|---|---:|---|
| Adaptive captured-response owner | 84.375 | 2/2 tests, compiled-artifact hit |
| Adaptive control owner | 231.915 | 12/12 tests, miss |
| Native task owners | 277.693 | 69/69 tests, miss |
| Native support | 140.229 | 22/22 steps, 80/80 tests |
| Workspace execution | 208.289 | 13/13 tests, miss |
| Workspace retention | 249.353 | 3/3 tests, miss |
| Workspace history | 217.919 | 3/3 tests, miss |
| Runtime selection | 262.797 | 4/4 tests, miss |
| Runtime succession | 244.637 | 4/4 tests, miss |
| Authoring and native HTTPS | 108.995 | 46/46 steps, 144/144 tests |

Native support also completes 20 process crashes and 40 reopens, with zero
original-effect reinvocations and zero automatic lookups. Its build reports
three new and four cached compiler steps; authoring and HTTPS reports 14 new
and five cached steps. Every cache-hit row still executes its selected tests.
Captured-response replay and archive import remain within the existing 64 MiB
requested-memory limit: the measured execution peak is 66,942,368 bytes.
Export passes its existing 32 MiB limit; a separate export peak was not measured.

Protean custody at committed `1d3885a9` passes all five tests in 362.198 seconds,
including 359.173 seconds executing an authenticated compiled-artifact hit.
The same source bytes first passed in 495.144 seconds after a miss: 129.600 seconds
building and 362.321 seconds executing. The regression exhausts descriptor lookup
with an absent schema and proves that unrelated compiler-fact caches stay empty;
valid semantic-value reuse and selection succeed without preinstalled facts.
The committed test process reports 13,165,297,664 bytes maximum resident memory
and 13,166,820,640 bytes peak memory footprint. These are whole-process measurements,
distinct from the bounded requested-memory owner checks above.

The shared witness's two generated-producer executions take 97.576 and 43.652
seconds, using 26,031 and 20,268 guest transitions respectively. The first
construction takes 99.074 seconds, its independent validation 0.794 seconds,
and producer compilation 0.007 seconds. These single local samples include
ordinary generated execution and publication; they do not predict model efficacy.

| Arm | Three-cut continuation ms | Publication ms | Artifact bytes | Evidence bytes |
|---|---:|---:|---:|---:|
| Generic | 33.009 | 8.256 | 234,530 | 50,635 |
| Built-in specialized | 50.382 | 46.711 | 26,986,920 | 23,337,881 |
| Generated validated | 36.801 | 8.689 | 625,054 | 440,856 |
| Instrumented | 178.232 | 47.860 | 26,988,453 | 23,339,190 |
| Reference guarded | 478.744 | 8.741 | 859,584 | 491,491 |

All five arms execute 21 guest transitions and publish the same 550 logical guest
checkpoint bytes across the selected cuts. The guarded measurement includes
25.240 ms reference execution, 18.308 ms candidate execution, and 20,214 retained
guard-capsule bytes. These samples do not establish an execution speedup or a
break-even repetition count for the generated candidate.

Workspace execution at `29da7d1` passes 13/13 tests in 198.914 seconds
(149.662 seconds build, 45.648 seconds tests, exact-key miss). This includes
captured semantic summary and pure-slice reads, prepared transaction replay, and
rejection of rehashed replies. Onward succession passes 4/4 in 232.472 seconds
(121.052 seconds build, 109.526 seconds tests, exact-key miss), including the
copied-custody forgery cases.
