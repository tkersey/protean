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
`8cfa8d64552a864f83713e4fc4ada78cbfe377dd` and Kosmos
`063d6c7090ce0486eb1f2e732f00583521030690`. The dependency lock authenticates the
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
| Generic artifact SHA-256 | `e02b586665200d6a0ba8cc18037fa6b33c81e7f979705c731ce0af2820aced9d` (231,649 bytes) |
| macOS executable SHA-256 | `97a3b335fac3bda49d858f9e07d578f95d0f4d1c17637a89bf4698575385a767` (10,310,968 bytes; authenticated build; current deployment qualification is recorded on the pull request) |
| WASM kernel SHA-256 | `f314c1bc56e268b83de3dcd3dfb6e9a050cb16bbe915099aaf54128a84fe897d` (current packaged kernel; generated-program correspondence passes; complete platform qualification is recorded on the pull request) |

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
| Horos construction and recovery | On `8cfa8d6`, safe `check check-native` passes 264/264 steps and 274/274 tests. Five focused checks cover sentinel-array storage, empty/nested arrays, fresh/cached specialization results and independent arrays-of-slices ownership. Both sentinel regressions failed before the correction. The complete roots retain lexical-capture, nominal-resource, public-example and well-typed permission-mutant coverage. [Linux source, contracts and independent installation](https://github.com/tkersey/horos/actions/runs/39034295981) pass; the Linux contract root reports 876/876 tests. |
| Kosmos native and optional platforms | On `063d6c7`, safe `check-native check-zig17 emit-native-input` passes 28/28 steps and 331/331 tests. Complete optional-platform and Linux results are recorded on [Kosmos #71](https://github.com/tkersey/kosmos/pull/71). The native specialization and reconstruction witnesses remain intact; pending platform results are not credited here. |
| Kosmos committed source package | Clean extraction and public native consumption pass 9/9 steps on `063d6c7`. The regenerated artifact differs from the predecessor only in its Horos package identifier: executable, recovery helpers and evidence bytes are identical. [Current Linux qualification](https://github.com/tkersey/kosmos/actions/runs/39034707193) is tracked on [Kosmos #71](https://github.com/tkersey/kosmos/pull/71). |
| Specialization economy | The recorded Horos `31aa79f` measurement contains 421 records across eleven families, all matching independent direct-native traces, canonical states and outcomes. Dynamic loops and repeated calls have positive start-plus-execution savings in all nine matched observations each. These are retained measurements of their stated inputs, not new corrected-compiler timings. Costs, artifact comparison and limits are in Kosmos `docs/semantic-economy.md`. |
| Protean owners, workspace and source correspondence | With the current authenticated dependencies, safe `check-protean` passes 39/39 steps and 154/154 tests; product/peer build plus `check-native-owner check-native-https check-workspace-programs check-workspace-semantics` passes 54/54 steps and 172/172 tests. Crash recovery verifies 16 crashes / 32 reopens without original reinvocation or automatic lookup. Native HTTPS verifies nine calls with no redirects/retries, exact bodies, TLS rejection, bounded responses and deadlines. |
| Current native delivery | The current executable is `97a3b335`. Its adaptive, process-placement, six runtime-scenario and independent downstream results are recorded on the pull request. The fixtures retain negative provider requests, response accounting, protocol/SIGINT/SIGTERM cancellation, reuse/foreign-runtime rejection, duplicate transfer, destination reopening and stale-source rejection. Downstream qualification independently acquires/builds/installs and compares program, assets, dependencies, compiler and target; absolute Node/Python rejection and source-tamper detection remain enforced. |
| Linux timing | On the predecessor Protean `0e9bf89`, [run 39029109805, attempt 2](https://github.com/tkersey/protean/actions/runs/39029109805) passes all thirteen qualification lanes and aggregate identity checks in 530 seconds from workflow start through the last job's completion. Exact compiled inputs were cached; every test and deployment scenario ran again. Rebuilding attempt 1 failed four ten-minute jobs. This establishes no cold-build timing pass and does not qualify the current successor. The workflow retains the same ten-minute ceiling. |
| Current old-task compatibility | The retention fixture runs the public Protean 5.0.0 executable after selecting the current product, checking continuation of its original question in a separate namespace. Baseline SHA-256: `53471a265a095481ab9eaccf3cfc685cfa85ed243a6104db1d0e2ac166a4f935`. Its current result is recorded on the pull request. |
| Current source/native/WASM correspondence | All nine generated cases and 328 boundaries pass independent Horos source comparison, native/WASM byte equality and alternating checkpoint producers with the current packaged kernel. Exact outer restore and duplicate-custody rejection pass. Outer packet SHA-256 is `c4764ece70fd25cb6773fe98ec5a38718f089592fbbd88a1110b146fff8f073c`; guest cut SHA-256 is `da41bbae343a1679a4fc31e10ada97e2cb7b27eeff44b3ad86a97005523c2ec8`. |
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
Kosmos `docs/semantic-economy.md` contains all tables and the raw-output digest.

In the recorded Horos `31aa79f` Apple M2 Pro safe measurement, mean
start-plus-execution time is
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
nine-minute Linux deadline. The offline demo now runs under the enclosing
workflow deadline; its former sixty-second Linux and 120-second macOS subprocess
limits were incidental fixture limits, not accepted performance requirements.
All demo assertions remain unchanged. Linux qualification must still complete
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
