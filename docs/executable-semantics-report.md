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
`31aa79fbb05c5861f81ef79d59710163673af2f8` and Kosmos
`08c1e9ccb0badbe794d272af0a2ef39bf95305a2`. The dependency lock authenticates the
selected source archives, Git trees and inventories. A repository checkout, a
source archive, a Zig package and a final executable have distinct identities.

| Identity | Value |
| --- | --- |
| Base | `kosmos.execution-base/1` |
| Native admission | `kosmos.horos-admission/3` |
| Private linear bridge | `kosmos.semantic-service/2` |
| Artifact envelope | `kosmos.semantic-artifact/2` |
| Compiler policy | `kosmos.source-lower/2` |
| Authored semantic source | `28a7dcbb8f79782b70255b7d9cc092ec2b3094d84a4fc2930d58d97a1b49f112` |
| Generic artifact SHA-256 | `915f7e5d2de855cfbd052a5e7e82bbe8eb4ff0de3e7f93d34cecef280cc13d95` (231,649 bytes) |
| macOS executable SHA-256 | `6892cf2fa2fe4456630e87b87c92cf7183168e8870f986f79b1467a9c4df7d51` (10,310,968 bytes; authenticated build passes 27/27 steps; all native deployment fixtures and six runtime scenarios pass) |
| WASM kernel SHA-256 | `b5113ac386f33e40584816f84e5124f1c00e3ea6dcbc002c1e0a3a1d022c4925` (current full local qualification passes) |

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

Artifact admission checks canonical content, digests, the complete base inventory,
helper images and recovery-map shapes. Independent compiler validation checks the
approved source, specialization derivation, lowered program, recovery evidence,
anchors and helper correspondence. Generic source, helper source, lowering input
and formal-parameter origins are reconstructed from the bound implementation.
Carried evidence supplies residual source and finite derivations, not replacement
trusted inputs. Recovery lowering retains general handler clauses when direct
tail conversion has no checked origin transport. The specialization checker uses
a capture-avoiding environment for every binder form. Mutant tests reject altered scalar behavior,
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

| Evidence | Result and scope |
| --- | --- |
| Horos construction and recovery | On `31aa79f`, safe `check` passes 264/264 steps and `check-native` passes 113/113 steps with 269 authoring tests. Fourteen targeted specialization/recovery tests include legal shadowing, binder-capture mutants, reordered formals, captured-input recovery and non-exportable aggregate residualization. [Linux source, contracts and independent installation](https://github.com/tkersey/horos/actions/runs/39009691163) pass. |
| Kosmos native and optional platforms | Current safe `check check-zig17 emit-native-input build-runtime -j2` passes 67/67 build steps and 258/258 executed tests; the unchanged storage root reuses its cached result. Independent source comparison covers 47 fixtures / 9,570 observations. All 45 JavaScript tests, 235 ABI3 boundaries / 23 transfers, Chromium/Firefox Workers, extracted runtime/CLI and unchanged-retry capacity checks pass. The scalar witness removes six packing calls and reduces base transitions from 11,901 to 8,931. |
| Kosmos committed source package | Clean extraction and public native consumption pass 9/9 steps on `08c1e9c`. The retained artifact matches the fresh derivation. [Current Linux qualification](https://github.com/tkersey/kosmos/actions/runs/39015724259) and its terminal outcome are tracked on [Kosmos #71](https://github.com/tkersey/kosmos/pull/71). |
| Specialization economy | All 421 records across eleven families match independent direct-native traces, canonical states and outcomes. Dynamic loops and repeated calls have positive start-plus-execution savings in all nine matched observations each. Detailed construction, validation, materialization and amortization costs are in Kosmos `docs/semantic-economy.md`. |
| Protean owners, workspace and source correspondence | Current safe `check-protean check-native-owner check-workspace-programs check-native-https check-workspace-semantics -j2` passes 77/77 steps and 326/326 executed tests, including all 155 owner and 17 workspace cases. Crash recovery verifies 16 crashes / 32 reopens without original reinvocation or automatic lookup. Native HTTPS verifies nine calls with no redirects/retries, exact bodies, TLS rejection, bounded responses and deadlines. |
| Current native delivery | Executable `6892cf2f` passes the adaptive fixture in 135.84 seconds and process placement in 1.15 seconds. This includes negative provider requests, response accounting, protocol/SIGINT/SIGTERM cancellation, reuse/foreign-runtime rejection, duplicate transfer, destination reopening and stale-source rejection. All six runtime scenarios pass in 450.99 seconds: outer mobility, guest-cut mobility, ordinary investigation, reused specialization, reframing and separate work/controller placement. The outer-mobility group takes 203.80 seconds; the other five scenarios take 450.66 seconds. These overlapping local groups are not additive or Linux timing evidence. Independent downstream acquisition/build/install passes in 325.00 seconds with matching program, assets, dependencies, compiler and target; absolute Node/Python rejection and source-tamper detection remain enforced. |
| Historical Linux timing | On preceding Protean `2b7e3fa`, complete cached qualification passed in 548/600 seconds. Rebuilding attempt 1 failed the limit; earlier attempts also exhausted ten minutes. This establishes neither a cold-build timing pass nor current-input acceptance. The current workflow retains the same ten-minute ceiling. |
| Current old-task compatibility | The public Protean 5.0.0 executable continued its old task after selection of `6892cf2f`, preserving its original question and separate namespaces. Baseline SHA-256: `53471a265a095481ab9eaccf3cfc685cfa85ed243a6104db1d0e2ac166a4f935`. |
| Current source/native/WASM correspondence | All nine generated cases and 328 boundaries pass independent Horos source comparison, native/WASM byte equality and alternating checkpoint producers. Exact outer restore and duplicate-custody rejection pass. Outer packet SHA-256 is `3056457fc101b3172b22c5ad76c98479b113b6121d3b1f470d0672109d51139b`; guest cut SHA-256 is `da41bbae343a1679a4fc31e10ada97e2cb7b27eeff44b3ad86a97005523c2ec8`. |
| Current Linux and serial reviews | Exact-head results and review dispositions are recorded on the pull request. This report does not substitute predecessor results or raw clean labels for those obligations. |

The first aggregate run failed the investigation fixture after mobility because
its function-wide argument array retained the previous scenario's placement
configuration. Each scenario now constructs its initial arguments from its own
selected fixture or the immutable empty-directory configuration. Controller
succession can change that scenario's arguments without affecting the next one.
The full six-scenario rerun passes with the original empty-directory assertion,
all mobility assertions and the same executable hash.

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
Kosmos `docs/semantic-economy.md` contains all tables and the raw-output digest.

On the current Apple M2 Pro safe build, mean start-plus-execution time is
48.639/43.930 ms generic/specialized for dynamic loops and 81.904/75.163 ms for
repeated calls. Including construction, independent validation, admission and
additional preparation gives estimated strict break-even at 3,200 and 2,242
new-session uses, respectively, under the measured equally weighted three-input
mix and reusable preparation owners. These are estimates from nine observations
per realization, not executions of thousands of sessions. Projection, restore,
network staging and durable publication are measured separately or explicitly
excluded; they can reverse these local savings.

Direct-native execution remains substantially faster. Long cleanup averages
226.962/432.725 ms generic/specialized start-plus-execution; several other
specialized workloads also remain slower. Specialized artifacts span roughly
13–33 MB; construction peaks range from about 5.6 to 10.1 GB of requested
allocator bytes, not RSS. Independent validation takes approximately 5.5–6.9
seconds for these artifacts. The report makes no universal speedup claim.

Protean CI retains a ten-minute per-job and whole-workflow ceiling. Independent
authoring, owner, workspace, correspondence, installation and deployment lanes
retain all original assertions. General runtime choices, placement, mid-clone
transfer and canonical guest-cut transfer run in four lanes; all deployment
executable hashes must match the independently packaged product.

Completed compilation can be reused only through an exact cache key containing
the complete Git tree, compiler executable/library/license contents and modes,
runner OS/architecture, safe mode and compilation profile. There is no prefix
fallback. Dependency authentication, each test, every deployment scenario and the
independent downstream build still execute. Compiled test roots use the same Zig
Compile objects and standard runner as the owning checks, with complete expected
test counts and leak/error failures. No cached test outcome receives credit.

macOS fixture execution is correctness qualification without a Linux wall-time
gate. Earlier macOS specialization, archive-export and packaging timeouts did not
establish semantic failures; subsequent unchanged assertions completed. Linux
runtime result polling retains its 120-second long-operation allowance and the
ten-minute workflow ceiling. Independent downstream subprocesses share a
nine-minute Linux deadline. The offline-demo allowances remain sixty seconds on
Linux and 120 seconds on macOS. No timeout or assertion was relaxed for the
current source reconstruction or slot representation.

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
was moved from Kosmos production modules to `test/oracle/`. Its independent tests
and benchmark oracle remain verification dependencies. Production guest execution
imports the authored semantic service and restricted base. Host-side source
construction and independent translation validation are outside that execution
closure and remain explicit trusted tooling.

## Completion requirements

Completion requires Linux qualification within the unchanged ten-minute limit,
the final proof inventory, and the requested serial reviews on frozen heads.
The pull request records their exact-head results. The canonical
guest-cut and actual mid-clone outer-capsule demonstrations are distinct required
observations; both remain in the owning runtime suite.
