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
`a58967d541402b3661c05b4d599926114df75123` and Kosmos
`0cb83a6255850851df24ec86ca90218c3db3ade0`. The dependency lock authenticates the
selected source archives, Git trees and inventories. A repository checkout, a
source archive, a Zig package and a final executable have distinct identities.

| Identity | Value |
| --- | --- |
| Base | `kosmos.execution-base/1` |
| Native admission | `kosmos.horos-admission/3` |
| Private linear bridge | `kosmos.semantic-service/2` |
| Artifact envelope | `kosmos.semantic-artifact/2` |
| Compiler policy | `kosmos.source-lower/2` |
| Authored semantic source | `1897ed209557817c475bd14d10614024ea5f327823aec7a143d0e0337eb3bbfc` |
| Generic artifact SHA-256 | `cb4af30f5c58aee7159f56aa4a08a5fb41a6748061260066edc24f7dadf74714` (231,839 bytes) |
| Predecessor `f7156d7` macOS executable SHA-256 | `7bddec5ef58c360bc9d75559238d32cd312c2ca59c72d65d8290b503097177c1` (10,458,712 bytes; authenticated build and macOS process qualification passed) |
| WASM kernel SHA-256 | `1a5319b0cbfa14712e8c3eec45fe348af08936bbacc6a009961902f22f8292c6` (unchanged Kosmos packaged kernel; predecessor `f7156d7` Protean correspondence qualification passed) |

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

Executor succession extends an immutable signed control with verified bilateral
transfer proofs. A prior executor's retained report is accepted as that operation's
receipt, while fresh cleanup observations must come from the current executor.
Every launch rechecks disclosure; a cached signature cannot authorize a new
transmission. Cancellation scheduling derives from retained ownership and current
custody, including terminal parents. Controller cancellation event revisions and
signed executor park observations preserve the ordering of fresh cancellation and
later explicit parking without comparing clocks between namespaces.

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

## Qualification evidence

The current tuple includes full runtime operation capsule recovery, an owning
pump-result API, collection at public cuts, release of dead initialization input,
and strong lease acquisition before checkpoint decoding. Protean consumes and
releases pump results in both controller and workspace paths. The table records macOS native, platform, process, downstream, compatibility and
source/native/WASM results on the named predecessor inputs. The new Kosmos pin
adds the measured retention-query optimization and factored qualification.
Successor integration, the ten-minute Linux workflow and fresh serial reviews
remain pending; their outcomes are recorded separately.

On predecessor `a46cbf8`, all thirteen Linux qualification lanes and source
accounting passed on attempt 2 of run 39068362474, but the aggregate rejected the
604-second gate interval (606 seconds through workflow completion). This remains
a failed workflow. Runtime fixture polling now preserves a one-second minimum
interval by counting elapsed controller work, removing the former unconditional
extra second per poll. The timing ceiling, attempt bounds, guest inputs, live
clone witness and all behavioral assertions are unchanged. This is fixture
pacing, not a claim of faster production execution. The successor needs a new
complete workflow result.

| Evidence | Result and scope |
| --- | --- |
| Horos construction and recovery | On `a58967d`, safe `check` passes 264/264 steps and 877/877 tests. Bounded-allocator recovery checks reject admitted oversized target domains through both public paths; valid unused maximum source region names and referenced sparse names still pass. The hostile regression returned `OutOfMemory` before the correction. The complete roots retain sentinel-array ownership, lexical-capture, nominal-resource, public-example and well-typed permission-mutant coverage. [Linux source, contracts and independent installation](https://github.com/tkersey/horos/actions/runs/39037753652) pass; the Linux contract root reports 877/877 tests. |
| Kosmos native and optional platforms | On `731a4ed`, the safe native aggregate passes 28/28 steps and 141/141 executed tests, with unchanged roots cached. All 83 public behavioral/lifecycle cases pass, including exhaustive allocation-failure sweeps. The optional-platform aggregate passes 49/49 steps: 47 independent-source fixtures, 9,570 observations, 235 ABI boundaries, 23 transfers, 45 JS cases, Chromium/Firefox Worker transfer, capacity-failure checks and packaged default API/CLI execution. Current Linux qualification is tracked on [Kosmos #71](https://github.com/tkersey/kosmos/pull/71). |
| Kosmos committed source package | A fresh export of committed `731a4ed`, fresh Zig package acquisition/extraction and public native consumption pass 9/9 steps. The production execution source and artifact are the exact inputs named above. |
| Specialization economy | Horos `a58967d` / Kosmos `731a4ed` yields 421 records across eleven families, all matching the immutable direct-native reference in traces, canonical states and outcomes. Only dynamic loops and repeated calls have positive measured mean start-plus-execution savings. Full costs, unfavorable cases and amortization assumptions are in Kosmos `docs/semantic-economy.md`. |
| Protean owners and workspace | On `f7156d7`, the safe native aggregate passes 59/59 steps and 179/179 tests; the authoring aggregate passes 39/39 steps, reusing unchanged cached roots. The six runtime contracts include frozen controller snapshots, onward executor routing and cancellation after abort/refusal. Crash recovery verifies 16 crashes / 32 reopens without original reinvocation or automatic lookup. Native HTTPS verifies nine calls with no redirects/retries, exact bodies, TLS rejection, bounded responses and deadlines. |
| Protean native delivery | Executable `7bddec5e` passes adaptive, authenticated process-placement and all six runtime scenarios, including actual mid-clone outer-capsule and canonical guest-cut mobility. Independent downstream acquisition/build/install passes with native-only build tools and matching dependency/compiler identities; its macOS elapsed time is 335.768 seconds, without a Linux timing claim. |
| Linux timing | On `a46cbf8`, [run 39068362474, attempt 2](https://github.com/tkersey/protean/actions/runs/39068362474) passed all thirteen qualification lanes but failed the 600-second whole-workflow gate at 604 seconds. Current `f7156d7` [run 39070271995](https://github.com/tkersey/protean/actions/runs/39070271995) attempt 1 hit the deadline during rebuilding. Attempt 2 reused exact compiled inputs but still timed out in workspace runtime and outer-capsule mobility; the other eleven qualification lanes passed. The fixture polling change alone was insufficient. No current Linux timing pass is claimed. The workspace-runtime suite now uses the same retained compiled-check path as the other large suites, and its standard runner passes all six tests locally. Further measured optimization and a complete Linux rerun remain required. |
| Old-task compatibility | The retention fixture passes with public Protean 5.0.0 SHA-256 `53471a265a095481ab9eaccf3cfc685cfa85ed243a6104db1d0e2ac166a4f935` and successor `7bddec5e`, checking continuation of the original question in a separate namespace. The owning build target passes 21/21 steps. |
| Source/native/WASM correspondence | All nine generated cases and 328 boundaries pass independent Horos source comparison, native/WASM byte equality and alternating checkpoint producers using kernel `1a5319b0`. Exact outer restore and duplicate-custody rejection pass. The target passes 18/18 steps. Outer packet SHA-256 is `8a67b70b74e704a9477c9e2075d6cdbe330a1eb2e94e014b226b81c6ef6f6c46`; guest cut SHA-256 is `da41bbae343a1679a4fc31e10ada97e2cb7b27eeff44b3ad86a97005523c2ec8`. |
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

## Costs and model evaluation

The eleven-family benchmark retains the original ten workloads and adds a longer
scalar chain. It measures direct-native, generic bootstrap, generic base,
specialized base and instrumented base on matched dynamic inputs. It separately
records construction, independent validation, admission, preparation, start,
execution, reconstruction, restore, capsules, switching, work and allocator bytes.
Kosmos `docs/semantic-economy.md` contains the current 421-record tables and raw
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

Protean CI retains a ten-minute per-job and whole-workflow ceiling. Independent
authoring, owner, workspace, correspondence, installation and deployment lanes
retain all original assertions. General runtime choices, placement, mid-clone
transfer and canonical guest-cut transfer run in four lanes; all deployment
executable hashes must match the independently packaged product.
The native adaptive CLI and native placement fixtures run independently. The
15 workspace cases are partitioned into nine execution, three retention and
three history/cancellation cases;
the six runtime cases into three selection/cancellation, two custody and one
succession case. These are disjoint filters over the same test roots, with exact
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
