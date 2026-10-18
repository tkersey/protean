# Executable semantics integration report

This report accompanies the Horos, Kosmos and Protean executable-semantics changes.
The results below retain their source and measurement scope. Exact-head Linux
qualification and serial-review status are reported on the pull request; pending
checks are not passing evidence. No release, installation, deployment or live
model evaluation is claimed.

## Sources and interfaces

| Repository | Implementation and changed interfaces |
| --- | --- |
| Horos | `src/source/specialize.zig` and its independent derivation checks; observed lowering, recovery evidence and retained source-parameter bindings. Ordinary source modules and BPI3 remain the construction and execution formats. |
| Kosmos | `src/semantic/` contains the authored guest machine, service, specializer integration, reconstruction, capsules, instrumentation and executable views. `src/base/` contains the checked first-order executor. Public `Session`, `Prepared`, `Resident` and invocation consumers use the portable guest facade. New exports include `RuntimeArtifact`, `RuntimeCompiler`, `RuntimeCapsule`, `RuntimeViews`, `RuntimeAnalysis` and `RuntimeInstrumentation`. |
| Protean | Workspace program/runtime/work contracts, native task ownership and archive validation, runtime selection/switching/views, signed placement and remote control, native stdio transport, deterministic demonstrations and the existing model-use evaluation runner. |

The integrated runtime inputs are Horos
`592eb0839326f2d8a423b59ce2746ab18ef5136a` and Kosmos
`ded2507d443708893496a17c3fec4cf4bcb1b625`. The dependency lock authenticates the
selected source archives, Git trees and inventories. A repository checkout, a
source archive, a Zig package and a final executable have distinct identities.

| Identity | Value |
| --- | --- |
| Base | `kosmos.execution-base/1` |
| Native admission | `kosmos.horos-admission/3` |
| Private linear bridge | `kosmos.semantic-service/2` |
| Artifact envelope | `kosmos.semantic-artifact/2` |
| Compiler policy | `kosmos.source-lower/2` |
| Authored semantic source | `cd73df16c3b9d3b0f3920fffa9c3d4a5ee71525cae6782f672e021d66da6ccb7` |
| Generic artifact SHA-256 | `c3be797414210c55c2ea639a8c5cf8494c5b118a82ffc7b5836832eeb86e940b` (231,838 bytes; terminal service state remains live through the final bounded finish cut) |
| macOS executable SHA-256 | `345c786a832b731f055b15c64b629472a41e16a3e10578d55bb42e1263a8eade` (10,442,296 bytes; authenticated build after the custody/runtime corrections with Kosmos `ded2507`; exact-head integration qualification is recorded on the pull request) |
| WASM kernel SHA-256 | `9cda4b3d473d2badbc38645f57a0ece6c9e933aa67a08feb2d2a4f4b121f1d19` (Kosmos `ded2507` packaged kernel; source/native/WASM, ABI, capacity and real-browser qualification pass) |

These are built artifacts, not published release assets. The native manifest
reports the authenticated inputs and compiler separately from the externally
computed executable hash.

## Semantic coverage and correspondence

The generic authored core covers scalar and aggregate operations, dynamic calls,
closures, cells, regions, resources, handlers, deep/shallow resumptions,
multi-shot cloning, disposal, cancellation, yields, external responses and
cleanup. Exhaustive opcode/terminator/schema dispatch makes new language cases an
explicit implementation decision. Unsupported specialization paths call the
portable core's general functions; they do not call the frozen native guest engine.

Specialization fixes the guest program projection while leaving guest inputs and
service commands dynamic. Residual calls handle recursion. Scalar bindings may
retain `(schema, u64 bits)` instead of repeatedly packing eight bytes. One sparse map contains a tagged ordinary or raw value at each key. Writes replace
that entry and its ownership; clears remove it, pruning selects live keys, and
ordered public projection encodes raw entries. Cross-map overlap has no
representation in a valid map. The byte encoding and decoding are inverse
positional-base-256 functions over the complete eight-byte/u64 domains.

Guest node/blob tables preserve stable IDs and chronological order. Frames retain
sparse bindings and ordered ownership. Reconstruction maps these structures to
canonical guest PST3, followed by independent guest admission. Hydration admits
the guest checkpoint and initializes the selected representation without executing
the preceding guest computation. Ordered table traversal and fused node conversion
avoid repeated numeric lookup and rebuilding during reconstruction.

These are rule arguments about the representation and operations. Differential
tests supply bounded independent observations, not a proof over every program.
Kosmos `docs/executable-semantics.md` gives the detailed operation arguments.

## Validation and control boundaries

The pure hypothetical interpreter validates raw arguments and the selected pending
reply against the embedded guest's admitted schema facts. Ordinary Horos functions
recognize canonical lengths, scalar values, aggregate shapes and UTF-8 before
initialization or response; they expose no native guest-transition callback or
live effect. Empty text slices are valid at every in-bounds offset, while nonempty
slices retain UTF-8 endpoint checks and existing range/capacity precedence.
The WASM default permits 128 MiB of working memory with 1 MiB of initial backing;
physical growth and explicit caller budgets remain enforced.

The composed correspondence checker derives the reachable source catalogs before
allocating target indexes. Every target catalog must fit within that source
domain, as required by the existing quotient relation. Sparse nominal region
names are normalized by actual references; unused names are not storage widths.
Independent raw-record checks remain responsible for correspondence meaning.

Artifact admission checks canonical content, digests, the complete base inventory,
helper images and recovery-map shapes. Independent compiler validation checks the
approved source, specialization derivation, lowered program, recovery evidence,
anchors and helper correspondence. Generic source, helper source, lowering input
and formal-parameter origins are reconstructed from the bound implementation.
Carried evidence supplies residual source and finite derivations, not replacement
trusted inputs. Recovery lowering retains general handler clauses when direct
tail conversion has no checked origin transport. The specialization checker uses
a capture-avoiding environment for every binder form. A closed function whose
direct calls need lexical captures stays a complete generic callee, retaining its
original binding and ownership scopes. Specializing that function as the root
returns the existing precise `UnsupportedSpecialization` result; the original
general program remains usable. Direct and transitive captures are classified
before fresh binders are created. Resource introducers and eliminators likewise
remain original generic functions, preserving nominal permission records. A direct
root request for an authorized function returns `UnsupportedSpecialization`.
Captured-lambda-producing functions are outside the covered first-order fragment;
they can leave the whole request unselected while the original module remains
usable. No new permission is granted to a clone. Mutant tests reject altered scalar behavior,
forged source/evidence or inventories, stale/missing recovery bindings, corrupted
clone mappings/cursors/work lists, duplicate-key slot trees and forged table sizes
or order. Well-typed altered images and substituted helpers are rejected even
with recomputed content identities; the old compiler policy is rejected before
decoding its incompatible evidence. Rehashing a mutant does not grant approval.

A controlled source mutation changes guest add to xor before lowering and
specialization. Both generic and regenerated specialized execution produce the
new result on three dynamic inputs, with the guest image unchanged and a new
specialization key. Extending the actual Horos opcode enum in an isolated source
copy also causes the base profile's exhaustive switch to fail compilation.

A bounded base pump can suspend inside clone or cleanup. That suspension is not
a guest result. An outer capsule retains the exact evaluator checkpoint, command,
input, realization and revisions; a guest-cut capsule carries canonical guest
state. Unavailable guest cuts are rejected. Switching reconstructs and hydrates a
private candidate, compares canonical guest bytes and asks the existing durable
owner to commit before exposing it. Uncertain publication fences both candidates.

Guest cancellation runs authored cleanup. Physical allocation, serialization,
transport or trace failures remain host failures and preserve the preceding
durable cut; they do not invent a guest exception. Terminal drivers release their
private evaluator before large result publication and import validation retires
its temporary evaluator before typed JSON validation. The existing 64 MiB owner
budget and large-result reservations remain enforced.

Specialization and independent validation allocate temporary proof arenas from
the service allocator. Their cleanup releases completed compiler phases even
when the caller uses a response arena whose individual frees are no-ops.

Source-array ownership preserves the complete valid array before recursively
copying its ordinary elements. This retains terminal sentinel storage, including
empty and nested arrays, while copied slice elements remain independently owned.
Both fresh and cached source-specialization results use that operation.

The native loop flushes writable output before testing output-stall deadlines.
Stopping a placement transport uses physical termination and reaping; it does not
send the semantic cancellation signal. Concrete tests exercise both distinctions.

## Runtime mobility and authority

Runtime artifacts are task-owned immutable content. Selection validates exact
source/compiler policy and guest binding. Analysis views and hypothetical
interpretations produce data; they cannot grant production execution or consume
a live external response.

Placement uses the existing task/work ownership boundary with authenticated peers,
signed offers/decisions, exclusive custody, disclosure checks and durable replay.
Remote checkpoint identities are signed identities, not local retention edges.
Transfer stages the runtime and exact capsule together. The source remains frozen
until the signed decision settles; duplicate acceptance is idempotent and stale
source execution is rejected. Signed controller succession lets a moved controller
continue controlling already-moved work without transferring ownership twice.
Freezing now retains the exact archive manifest and its object closure in the
same source transaction. Later local sibling progress cannot change the offered
cut. Snapshot records stay in native storage and have no portable archive kind.
Compatibility reads admitted artifact metadata without creating a resident.
Native JSON projections own their nested text after decoded records are released.

Snapshot validation restores a private session and compares its canonical
publication without replacing the controller's live resident or writing another
Store publication. Runtime identity follows the exact compiled guest image;
distinct source artifacts with that image can share a runtime. Its immutable
`origin_program` records the first admitted source, while each work item retains
its own program and exposed ports. Runtime observations must match the actual
task-owned record, including provenance.

Ordinary archive import grants no execution, whether copied custody is local,
frozen or omitted, and whether placement is configured or disabled. Native local
admission stays in the original namespace. Import verifies bilateral acceptance
against the original frozen record, converts copied custody to remote data, and
activates only the accepted subject in the same transaction. A moved controller
can follow authenticated executor succession for a child whose offer was created
after controller transfer. Cold retention audit independently traverses each
typed workspace publication command, including source capsules used by switching.

Executor succession extends an immutable signed control with verified bilateral
transfer proofs. A prior executor's retained report is accepted as that operation's
receipt, while fresh cleanup observations must come from the current executor.
Every launch rechecks disclosure; a cached signature cannot authorize a new
transmission. Cancellation scheduling derives from retained ownership and current
custody, including terminal parents. Controller cancellation event revisions and
signed executor park observations preserve the ordering of fresh cancellation and
later explicit parking without comparing clocks between namespaces.
Root cancellation retains queued scheduling intent across freeze and refusal or
abort. Host parking also covers owned frozen roots, so restoring local custody
does not override a later explicit park; a fresh cancellation can select cleanup
again. Regression fixtures exercise both transfer outcomes and both scheduling
orders.

The deterministic native demonstration includes ordinary investigation, one
specialization reused on changed inputs, leaving a runtime investigation for source
evidence, and separate work/controller movement. The first real branch supplies a guest view
to an ordinary retention-query program; its nonempty path is checked against the
view, and the original work revisions and port remain unchanged. The hardest scenario suspends
inside an actual progressed multi-shot clone, moves its selected instrumented
runtime, resumes both alternatives (366 and 376), then completes the real outer
cleanup. A second version requests a canonical guest cut after specialization,
moves it to a fresh native executor, checks the identical selected runtime,
capsule and execution revision, and only then supplies the second branch input.
Its first prefix and response are not replayed. Local capsule-verifier tests alone
do not establish these host laws.
The outer-capsule version additionally switches back to the packaged generic runtime
through signed remote control, preserving the exact execution revision and second
branch value. It then moves its controller; that signed transfer archive retains
all three requested switches for accounting. Evaluation
arm checks normalize these remote wrappers; pure-tool comparisons permit only
terminal owner-scheduled start, wait and collect, and reject guest views.

## Qualification evidence

The current tuple includes full runtime operation capsule recovery, an owning
pump-result API, collection at public cuts, release of dead initialization input,
and strong lease acquisition before checkpoint decoding. Protean consumes and
releases pump results in both controller and workspace paths. The table preserves recorded macOS, platform, process, compatibility and
source/native/WASM observations with their named source revisions. Exact-head
Linux cold/cache-assisted results and serial-review dispositions are recorded on
[Protean #57](https://github.com/tkersey/protean/pull/57); the historical rows do
not qualify a successor.

On predecessor `a46cbf8`, all thirteen Linux qualification lanes and source
accounting passed on attempt 2 of run 39068362474, but the aggregate rejected the
604-second gate interval (606 seconds through workflow completion). This remains
a failed workflow. Runtime fixture polling now preserves a one-second minimum
interval by counting elapsed controller work, removing the former unconditional
extra second per poll. The timing ceiling, attempt bounds, guest inputs, live
clone witness and all behavioral assertions are unchanged. This is fixture
pacing, not a claim of faster production execution. Current exact-head workflow
results are recorded on the pull request.

| Evidence | Result and scope |
| --- | --- |
| Horos construction and recovery | On `592eb08`, safe `check` passes 264/264 steps and 878/878 tests. The added sparse-reachability check preserves sorted membership through cycles, disconnected blocks and allocation failure. Bounded-allocator recovery checks reject admitted oversized target domains through both public paths; valid unused maximum source region names and referenced sparse names still pass. The hostile regression returned `OutOfMemory` before the correction. The complete roots retain sentinel-array ownership, lexical-capture, nominal-resource, public-example and well-typed permission-mutant coverage. [Linux source, contracts and independent installation](https://github.com/tkersey/horos/actions/runs/39092955413) pass; the Linux contract root reports 878/878 tests. |
| Kosmos native and optional platforms | On `200e06c`, safe `check build-runtime` passes 64/64 steps and 308/308 tests in 378.485 seconds. All 83 tests in the complete session root remain selected; the three CI groups execute 53+15+17 tests because their anonymous registration test runs once per group. The same run passes 47 independent-source fixtures and 9,570 observations, 235 ABI boundaries and 23 transfers, 45 JS cases, Chromium/Firefox Worker transfer, capacity-failure checks and packaged default API/CLI execution. [Cache-assisted Linux qualification](https://github.com/tkersey/kosmos/actions/runs/39094345449) passes in 513 seconds, with every job at or below 506 seconds. [Cold qualification](https://github.com/tkersey/kosmos/actions/runs/39094882943) passes in 534 seconds, with every job at or below 524 seconds. |
| Kosmos committed source package | A fresh export of committed `200e06c`, fresh Zig package acquisition/extraction and public native consumption pass 9/9 steps in 32.205 seconds. The production execution source and artifact are the exact inputs named above. |
| Specialization economy | Horos `592eb08` / Kosmos `200e06c` yields 421 records across eleven families, all matching the immutable direct-native reference in traces, canonical states and outcomes. Only dynamic loops and repeated calls have positive measured mean start-plus-execution savings. Full costs, unfavorable cases and amortization assumptions are in Kosmos `docs/semantic-economy.md`. |
| Protean owners and workspace | On the preceding `200e06c` Kosmos pin, safe authoring, native-owner and general-workspace roots pass 333/333 tests. The six runtime contracts pass as three selection/cancellation, two custody and one succession cases, including cache invalidation, frozen controller snapshots and onward executor routing. Crash recovery verifies 16 crashes / 32 reopens without original reinvocation or automatic lookup. Native HTTPS verifies nine calls with no redirects/retries, exact bodies, TLS rejection, bounded responses and deadlines. The initial combined command had an incorrect WASM filename; only correspondence failed, and its corrected 18/18-step run passed separately. |
| Protean native delivery | Executable `850bc9a7` passes adaptive, authenticated process-placement and all six runtime scenarios, including actual mid-clone outer-capsule and canonical guest-cut mobility. Independent downstream acquisition/build/install uses native-only build tools and compares dependency/compiler identities; exact-head results are recorded on the pull request. |
| Linux timing history | On `a46cbf8`, [run 39068362474, attempt 2](https://github.com/tkersey/protean/actions/runs/39068362474) passed all thirteen qualification lanes but failed the 600-second whole-workflow gate at 604 seconds. The subsequent `f7156d7` [run 39070271995](https://github.com/tkersey/protean/actions/runs/39070271995) attempt 1 hit the deadline during rebuilding. Attempt 2 reused exact compiled inputs but still timed out in workspace runtime and outer-capsule mobility; the other eleven qualification lanes passed. The fixture polling change alone was insufficient. The workspace-runtime suite now uses the same retained compiled-check path as the other large suites. Later measurements and mechanism changes are described below; the current complete workflow result is linked from the pull request. |
| Old-task compatibility | The retention fixture passes with public Protean 5.0.0 SHA-256 `53471a265a095481ab9eaccf3cfc685cfa85ed243a6104db1d0e2ac166a4f935` and successor `850bc9a7`, checking continuation of the original question under the retained executable and a separate namespace for the new runtime. |
| Source/native/WASM correspondence | All nine generated cases and 328 boundaries pass independent Horos source comparison, native/WASM byte equality and alternating checkpoint producers using kernel `00e1ccb3`. Exact outer restore and duplicate-custody rejection pass. The target passes 18/18 steps. Outer packet SHA-256 is `efda825c0c6ee5dfa6d0ed911110fd4f00283ba85ff9202488fa76b98f0dc4de`; guest cut SHA-256 is `da41bbae343a1679a4fc31e10ada97e2cb7b27eeff44b3ad86a97005523c2ec8`. |
| Current Linux and serial reviews | Exact-head results and review dispositions are recorded on the pull request. This report does not substitute predecessor results or raw clean labels for those obligations. |

The first aggregate run failed the investigation fixture after mobility because
its function-wide argument array retained the previous scenario's placement
configuration. Each scenario now constructs its initial arguments from its own
selected fixture or the immutable empty-directory configuration. Controller
succession can change that scenario's arguments without affecting the next one.
The predecessor `0e9bf89` six-scenario rerun passed with the original empty-directory
assertion, all mobility assertions and the same executable hash. The current
successor deployment results are recorded on the pull request.

WASM common-domain tests explicitly provide sufficient working memory for the
authored evaluator; this is a larger physical requirement than the old native
guest engine. Capacity and allocator-failure tests remain separate. Filesystem,
process isolation, OS cryptography/entropy, SQLite durability and correct operator
peer configuration remain environmental premises.

Kosmos successor `fd21a13` changes baseline acquisition and the measurement report;
its production implementation, authored semantic source and packaged core are
unchanged from `200e06c`. After independent global-cache eviction, its authenticated
fetch restored the immutable baseline and executed all 68 semantic tests with the
local compiler cache retained. A fresh committed source package and independent
native consumer passed 9/9 steps in 32.550 seconds. Final integrated successor
qualification is recorded on the pull request, separately from the preceding rows.

Kosmos successor `ded2507` retains the actual service state through its final
ordinary base return. Every bounded finish cut remains transferable until the
service closes, while guest cuts remain unavailable during the operation. The
owning regression failed with `MissingRecoveryAnchor` before the change and passes
for completed, failed and cancelled guests under generic and specialized cores,
retiring the source before each exact-custody restore. The complete local source
check passes 309 tests, 47 source fixtures / 9,570 observations, ABI, browser,
capacity and package checks in 367.786 seconds. A fresh committed package consumer
passes 9/9 steps in 29.678 seconds. The refreshed cost run has 421 records across
all eleven families; mean start-plus-execution savings remain positive only for
dynamic loops and repeated calls, with estimated construction amortization at
1,284 and 928 new sessions respectively under the report's stated assumptions.
These are new-core observations; the preceding rows retain their historical scope.
Current integrated deployment and Linux qualification are recorded on the pull request.

## Qualification latency measurements

The first Linux Kosmos qualification spent 40 minutes 42 seconds in native
qualification before later optional-platform work timed out. Repeated allocation
failure sweeps rebuilt admitted inputs and replayed the same transaction through
several wrappers. The revised checks keep exhaustive failure testing at the
owning preparation, storage and transaction boundaries, and exercise the final
publication failure and exact retry on each real lifecycle fixture. Independent
source comparison still runs all 47 fixtures and 9,570 observations. Disjoint
build roots avoid repeating native checks through the optional-platform root.
Cold and cache-assisted Linux results for Kosmos `3b1b46e` are 560 and 444 seconds
for the complete workflow, respectively; the longest jobs are 550 and 436 seconds.
These results precede the new Horos dependency pin.

On Protean `f62b73f`, [run 39086408108](https://github.com/tkersey/protean/actions/runs/39086408108)
completed 17 of 20 qualification lanes; placement, outer-capsule and guest-cut
runtime lanes reached the ten-minute deadline, and the terminal gate failed.
The workflow ended after 624 seconds including termination. Those runtime lanes
spent 255–271 seconds building their compiled inputs, in addition to approximately
60–90 seconds of setup and cache handling. The remaining execution cost was
therefore material even after the earlier fixture and build-graph changes.

Protean's full local outer-capsule scenario exposed repeated independent runtime
validation after successful specialization. The service now retains the exact
validated immutable artifact under its content identity and the current store
integrity epoch. Selection still checks the saved task-owned record and program
binding before consulting the retained artifact. Integrity changes invalidate
reuse. The three selection/cancellation tests include cache reuse and epoch
invalidation. In the measured scenario, specialization fell from 24.663 to 18.064
seconds; whole-scenario measurements overlap at approximately 160–166 seconds,
so that experiment alone establishes no whole-scenario gain.

Sampling a symbol-bearing executable then attributed 1,552 of 2,444 remote
validation samples to Horos borrow-flow settlement. Each query scanned every
program block even when only a small subgraph was reachable. The selected Horos
change retains the exact reachability membership and a sorted list of its members;
subsequent scans visit that list in the former numeric block order. Query meaning,
fact order, independent validation and rejection rules remain unchanged. Cyclic
and disconnected graphs check exact membership and order at every allocation
failure; existing borrow admission cases and the full native/WASM roots remain.

A controlled local product with only the Horos source substitution completed all
50 calls and assertions of the real outer-capsule scenario in 121.682 seconds,
compared with 160.487 seconds for the retained-validation candidate. Specialization
took 8.498 rather than 18.064 seconds. Both runs produced a 21,305,677-byte artifact
and a 98,658-byte capsule and retained the branch, controller-transfer and cleanup
assertions. This is a single-run mechanism comparison, approximately 24% lower
elapsed time, not qualification of the final authenticated dependency tuple or a
Linux performance result. The final tuple requires its own complete cold and warm
workflow runs.

The authenticated macOS product using Horos `592eb08` and Kosmos `200e06c`
completed the same full outer-capsule scenario in 116.984 seconds with all 50 calls
and assertions passing. Its SHA-256 is
`850bc9a76a3cd351155d08910316b4039c72a485df210a32563ed7468f348a41`
(10,425,880 bytes). The admitted artifact and capsule remained 21,305,677 and
98,658 bytes. This confirms the selected construction on the actual dependency
lock; it is a local measurement and does not establish Linux workflow latency.

## Costs and model evaluation

The eleven-family benchmark retains the original ten workloads and adds a longer
scalar chain. It measures direct-native, generic bootstrap, generic base,
specialized base and instrumented base on matched dynamic inputs. It separately
records construction, independent validation, admission, preparation, start,
execution, reconstruction, restore, capsules, switching, work and allocator bytes.
Kosmos `docs/semantic-economy.md` contains the recorded 421-record tables and raw
output digest `bc1175ec16be60e26927dd9112d23386d225fc5c856588331c284622ebdc71a5`.
The native reference is the immutable `62279bc` archive; unavailable historical
projection counters remain null. It shares the selected Horos admission library,
so this is independent execution evidence, not independent admission evidence.

In the Horos `a58967d` / Kosmos `731a4ed` Apple M2 Pro safe measurement, mean
start-plus-execution time is 48.811/44.200 ms generic/specialized for dynamic loops
and 81.067/74.529 ms for repeated calls. Including construction, independent
validation, admission and additional preparation gives estimated strict break-even
at 3,242 and 2,285 new-session uses, respectively, under the measured equally
weighted three-input mix and reusable preparation owners. These are estimates from
nine observations per realization, not executions of thousands of sessions.
Projection, restore, network staging and durable publication are measured
separately or explicitly excluded; they can reverse these local savings.

Direct-native execution remains substantially faster. Long cleanup averages
288.804/480.648 ms generic/specialized start-plus-execution. All nine other
families have no measured finite break-even under this calculation. Specialized
artifacts span roughly 13.6–30.5 MB; construction peaks range from about 5.8 to
10.1 GB of requested allocator bytes, not RSS. Independent validation takes
approximately 5.4–6.8 seconds. These measurements establish no universal speedup.

Protean CI retains a ten-minute per-job and whole-workflow ceiling. Ordinary Zig test runners always execute, including authoring, helper, adaptive-context and workspace-recovery roots. Compiler artifacts remain reusable; cached test outcomes do not qualify a warm run. Independent
authoring, owner, workspace, correspondence, installation and deployment lanes
retain all original assertions. General runtime choices, placement, mid-clone
transfer and canonical guest-cut transfer run in four lanes; all deployment
executable hashes must match the independently packaged product.
The native adaptive CLI and native placement fixtures run independently. The
15 workspace cases are partitioned into nine execution, three retention and
three history/cancellation cases;
the seven runtime cases into three selection/cancellation, two custody and two
succession cases. These are disjoint filters over the same test roots, with exact
executed counts checked in CI. The ordinary build targets still run the full roots.
The 14 adaptive-owner cases similarly divide into three capture-recovery and
eleven control/reconciliation cases; their previous combined job took 589 seconds.

The scripted provider waits for real transfer completion through the public
status API. After observing a queued remote control, it waits for the native
owner's retained report using a read-only database connection and the schema
from the actual transferred archive. These observations only schedule the next
model reply. A transient SQLite busy result waits within that same bounded
observation loop; it does not count as a completed control. The unchanged model
action still obtains and checks custody and
the signed remote result. No fixture supplies an acknowledgement or advances
the transferred work outside the prescribed model actions.

The large placement schema uses the same typed JSON writer at discovery startup,
with an exact-size host allocation, instead of materializing its 180,672 bytes
inside the compiler. Native contract and source-string validation remain at
compile time. The public schema bytes and descriptions are unchanged. A focused
seven-schema build measured 51.7 seconds with compile-time output and 6.2 seconds
with runtime output; the complete product build and Linux job timings are separate
measurements. Allocation failure remains explicit, and the parser owns its copied
strings before the schema buffer is released through the owning allocator.

On `5137efa`, [Linux run 39083493949](https://github.com/tkersey/protean/actions/runs/39083493949)
passed eighteen of twenty initial jobs, but native adaptive and guest-cut mobility
hit the ten-minute deadline. Their build steps took 269 and 262 seconds, leaving
about 290 seconds for execution. Guest mobility also built the full verification
peer (reported as two minutes), although it used only source emission. That peer
compilation competed with the product's three-minute compile on the same runner.
The mobility lanes now build a smaller source/inspection peer; the full independent
correspondence peer remains in its owning job. The smaller peer compiled locally
in 11 seconds (15 seconds for the build step with cached prerequisites), versus
57 seconds for the full peer (58.3 seconds for its build step). Its
10,243-byte source transport exactly matched the full peer. This local result is
not a cold Linux workflow measurement.

Native adaptive qualification now separates retained reuse/foreign-program checks
from control/recovery, reverse/disabled cases and the offline demo. The unchanged
fixtures passed locally in 96.0 and 42.9 seconds respectively. Moving source
accounting into the authoring job keeps the total at twenty parallel jobs.
Guest-cut mobility selects owner scheduling between exposed ports, retaining all
its assertions; the outer-clone scenario selects explicit scheduling before the
clone operation. On the same
local production executable, the guest-cut fixture passed in 130.9 seconds versus
150.6 seconds with explicit scheduling. The narrowed peer also passed all 50 outer-capsule
mobility actions, including live clone inspection, controller succession and
cleanup, in 169.9 seconds locally. Complete cold and warm Linux qualification
of these changes remains required; no timing pass is inferred from local results.

Completed compilation can be reused only through an exact cache key containing
the Git build inputs, compiler executable/library/license contents and modes,
runner OS/architecture, safe mode and compilation profile. There is no prefix
fallback for compiled executables. The audited root `docs/`, `README.md` and
`AGENTS.md` prose is excluded; embedded Markdown in application skills remains
an input. Raw compiler caches can reuse older entries because Zig validates
their actual inputs. Dependency authentication, each test, every deployment scenario and the
independent downstream build still execute. Compiled test roots use the same Zig
Compile objects and standard runner as the owning checks, with complete expected
test counts and leak/error failures. No cached test outcome receives credit.

macOS fixture execution is correctness qualification without a Linux wall-time
gate. Earlier macOS specialization, archive-export and packaging timeouts did not
establish semantic failures; subsequent unchanged assertions completed. Linux
runtime result polling retains its 120-second long-operation allowance and the
ten-minute workflow ceiling. Independent downstream subprocesses share a
nine-minute Linux deadline. The offline demo now runs under the enclosing
workflow deadline; its former sixty-second Linux and 120-second macOS subprocess
limits were incidental fixture limits, not accepted performance requirements.
The offline demo and independent provider fixtures use separate state directories
and run concurrently; every operation and cleanup must finish. All demo assertions
remain unchanged. Linux qualification must still complete
the entire workflow within ten minutes.

On `3325717`, [Linux run 39096051592](https://github.com/tkersey/protean/actions/runs/39096051592)
completed eighteen of twenty qualification jobs but failed the workflow deadline
at 621 seconds including teardown. The outer-capsule job spent 272 seconds
building and was cancelled after 288 seconds of fixture execution. The workspace
job spent 283 seconds building; its assertions passed in 256 seconds, but the job
reached its deadline during teardown. Cache saving added five to six seconds;
it was not the dominant cost.

The two mobility demonstrations had independently repeated the complete
retention-query sequence. That sequence and every one of its assertions now run
in the canonical guest-cut demonstration, followed by specialization, transfer,
the second alternative and cleanup. The mid-clone demonstration retains its
actual live-clone inspection, `GuestCutUnavailable` rejection, exact outer capsule,
work and controller custody transfers, both branch results and remote cancellation
cleanup. Its separate query work did not advance the subject, as the retained
query fixture's revision, realization and port-equality assertions check. This
factoring removes duplicate analysis work without replacing either mobility
fixture. On the identical safe executable, the outer demonstration passed in
96.0 seconds with 41 model actions, versus 117.0 seconds with 50 actions before
factoring. The full canonical guest-cut demonstration passed in 92.9 seconds.
These are local macOS observations, not Linux workflow qualification.

The foreign-reference rejection fixture now follows the shorter reverse-work
trace in the other native group. It still receives an actual completed program
from a different task in the same namespace and checks `ArtifactUnavailable`.
The long reuse trace, all twelve work results, restart, ordered archive evidence
and control-revision assertions remain intact. Every native group still runs.
The factored workspace and control groups passed locally in 86.8 and 41.4 seconds
respectively; the former still executed all 55 provider calls, while the latter
executed the unchanged foreign-reference rejection after the reverse trace.

On `a137967`, [Linux run 39098548717](https://github.com/tkersey/protean/actions/runs/39098548717)
passed all twenty qualification jobs, with a maximum job duration of 592 seconds.
The complete workflow still failed at 605 seconds. The terminal identity gate
spent six seconds reading independent artifacts serially. Those eight reads now
run concurrently, with every artifact digest and native/runtime/downstream
identity comparison preserved. Against the same completed run's immutable
artifacts, the complete gate script passed locally in 1.28 seconds versus 7.72
seconds for its serial form. Final workflow timing still requires qualification.

On `67ecb4e`, [cache-assisted Linux run 39099279759](https://github.com/tkersey/protean/actions/runs/39099279759)
passed in 594 seconds for the whole workflow, with a maximum job duration of
585 seconds. It executed every selected test and retained lifecycle fixture.
This run precedes the final Kosmos dependency refresh; it is not a cold result.

On `5f43afa`, [Linux run 39100578965](https://github.com/tkersey/protean/actions/runs/39100578965)
passed all twenty qualification jobs but failed the whole-workflow gate at
602 seconds. The longest job was outer mobility at 595 seconds, including
275 seconds of compilation, 251 seconds of actual fixture execution and an
eight-second optional compiler-cache upload. Both mobility jobs build the same
product and verification peer. Guest mobility now publishes their shared build
caches; outer mobility restores those same inputs and executes its own complete
fixture without publishing a duplicate cache. Cold qualification skips optional
compiler-cache publication as well as restoration. Test commands, fixture inputs,
assertions, safety settings, admission and the 600-second gates are unchanged.
The removed upload is measured work; final end-to-end timing still requires the
successor's complete cold and cache-assisted runs.

On `1b241d2`, [Linux run 39101619804](https://github.com/tkersey/protean/actions/runs/39101619804)
again passed all twenty qualification jobs, but the full workflow took 606 seconds.
Outer mobility finished in 548 seconds with both duplicate uploads skipped.
Runtime placement became the longest job at 595 seconds: 269 seconds compiling,
228 seconds executing, and eight seconds uploading duplicate compiler artifacts;
native workspace took 587 seconds with a six-second duplicate upload. The native
job now publishes the shared product caches for these consumers. Each consumer
still authenticates its inputs, builds on a cache miss, and executes its complete
fixture. Cache publication has one producer per shared build profile; the same
commands, assertions, safety settings and time limits remain. Final cold and
cache-assisted timings remain unproved until their complete successor runs.

On `6fe8f6e`, [cache-assisted run 39102354869](https://github.com/tkersey/protean/actions/runs/39102354869)
passed in 599 seconds, with a 589-second longest job. The subsequent
[cold run 39102988826](https://github.com/tkersey/protean/actions/runs/39102988826)
failed after 626 seconds including deadline cancellation; outer mobility was
cancelled, while the other nineteen qualification jobs passed. Compiler and
transport cache restoration and optional compiler-cache publication were skipped.
Outer mobility spent 73 seconds setting up Zig, including a 61.751-second download
from a randomly selected mirror. Four jobs downloading from `zigmirror.com` took
2.417, 3.430, 3.896 and 2.341 seconds. The workflow now selects that mirror through
the pinned setup action's supported input. The action retains upstream minisign
and trusted archive-name verification. The override removes automatic mirror
fallback; these samples do not guarantee future availability or download time.
The cold deadline remains unqualified until a complete successor run passes.

On `528012b`, [Linux run 39116449188](https://github.com/tkersey/protean/actions/runs/39116449188)
passed all twenty qualification jobs but failed the complete-workflow limit at
605 seconds. Guest mobility took 595 seconds, including 279 seconds compiling
and 246 seconds executing. The separate remote-runtime-switch assertion and its
terminal accounting export were moved after the second branch in the shorter
outer-capsule scenario. Guest mobility retains the complete required retention
query and uses its authenticated work-transfer archive for accounting. Both
scenarios retain their migration, branch and cleanup assertions. On the unchanged
macOS executable, the redistributed scenarios passed in 80.3 and 97.6 seconds;
these local observations do not establish the final Linux timing result.

On `4721583`, cache-assisted qualification passed in 599 seconds, with a
589-second longest job. Cold qualification reached 623 seconds after cancelling
outer mobility: its compile step took 290 seconds, and all 43 prescribed actions
finished before the final accounting export reached the deadline. The fixture
now moves its controller after the remote switch and accounts the actual signed
transfer archive, avoiding that extra export. Its ordinary prefix uses owner
scheduling; at the first branch it explicitly selects manual scheduling before
the clone. Added assertions preserve the execution revision, runtime revision
and exposed port across that policy change. The same executable passed this
39-action trace in 86.4 seconds locally, including the original clone, branch,
transfer, remote-switch and cleanup checks. Final cold and warm results remain
separate observations recorded on the pull request.

An isolated attempt to move C compilation into the final Zig compile was not
retained: local cold cross-build time changed from 189.0 to 206.3 seconds, and a
comparison using the same already emitted assets changed from 118.4 to 124.5
seconds. Both produced identical C objects, but neither measured a useful gain.
Production compiler flags, backend, safety checks and runtime code remain unchanged
by this fixture factoring. Final cold and cache-assisted workflow results are
recorded on the pull request for their exact revisions.

`tools/evaluation/workspace.mjs prepare --suite runtime` prepares matched ordinary,
generic and runtime-optional arms for repetitive work, adaptive exploration and a
small investigation. It retains input/expected-output hashes and counts actual
controller/delegated calls, runtime artifacts, current capsules and requested
specialization/switches. Unmeasured construction/validation timing and economic
judgments remain null. Prepared fixtures make no paid model calls. Live model
selection quality, token cost and end-to-end economic benefit remain unmeasured.

## Trusted native inventory and retirement

The production native substrate retains ordinary scalar/data operations, aggregate
storage and collection, activation frames, direct calls, base control, admitted
image/preparation leases, data/schema/value codecs, canonical serialization,
physical allocation and the linear service bridge. The guest facade retains
response binding, receipts, transactional publication and host-owned authorization.
Protean retains OS transport, cryptography, archive admission and SQLite custody.

The complete native guest instruction/control, resumption, clone and unwind engine
has been removed from the Kosmos source tree. Differential checks and benchmarks
fetch the immutable, hash-pinned `62279bce8e916e7fe613fe4575b3bc12e530596f`
reference. Behavioral and lifecycle assertions run against the new public engine;
historical-engine tests are not used to qualify it. Production guest execution
imports the authored semantic service and restricted base. Host-side source
construction and independent translation validation are outside that execution
closure and remain explicit trusted tooling.

## Completion requirements

Completion requires Linux qualification within the unchanged ten-minute limit,
the final proof inventory, and the requested serial reviews on frozen heads.
The pull request records their exact-head results. The canonical
guest-cut and actual mid-clone outer-capsule demonstrations are distinct required
observations; both remain in the owning runtime suite.
