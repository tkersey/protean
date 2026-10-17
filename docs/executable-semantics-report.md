# Executable semantics integration report

This report accompanies the Horos, Kosmos and Protean executable-semantics changes.
Qualification is still in progress; the pending items below are not passing
evidence. No release, installation, deployment or live model evaluation is claimed.

## Sources and interfaces

| Repository | Implementation and changed interfaces |
| --- | --- |
| Horos | `src/source/specialize.zig` and its independent derivation checks; observed lowering, recovery evidence and retained source-parameter bindings. Ordinary source modules and BPI3 remain the construction and execution formats. |
| Kosmos | `src/semantic/` contains the authored guest machine, service, specializer integration, reconstruction, capsules, instrumentation and executable views. `src/base/` contains the checked first-order executor. Public `Session`, `Prepared`, `Resident` and invocation consumers use the portable guest facade. New exports include `RuntimeArtifact`, `RuntimeCompiler`, `RuntimeCapsule`, `RuntimeViews`, `RuntimeAnalysis` and `RuntimeInstrumentation`. |
| Protean | Workspace program/runtime/work contracts, native task ownership and archive validation, runtime selection/switching/views, signed placement and remote control, native stdio transport, deterministic demonstrations and the existing model-use evaluation runner. |

The integrated runtime inputs are Horos
`4b29dd0a2c9ccce6d5cd424542389bc8bcfcf9b1` and Kosmos
`aa263f6c5e33812abe0d260fc090c4f62daffc77`. The dependency lock authenticates the
selected source archives, Git trees and inventories. A repository checkout, a
source archive, a Zig package and a final executable have distinct identities.

| Identity | Value |
| --- | --- |
| Base | `kosmos.execution-base/1` |
| Native admission | `kosmos.horos-admission/3` |
| Private linear bridge | `kosmos.semantic-service/2` |
| Artifact envelope | `kosmos.semantic-artifact/2` |
| Compiler policy | `kosmos.source-lower/1` |
| Authored semantic source | `aa7a3b20f6dc0dd6d34efab9254109aeab4811249e83339984d373f0c0063571` |
| Generic artifact SHA-256 | `e58be22ba27ad3586b906a4b73d0647fc5fafcb37c2fc859af3ebd327d389a48` (1,186,158 bytes) |
| macOS executable SHA-256 | `c5d8dbc91564ea348a1714d095989b77e1e91237248b287aba4536ba9a33c2a7` (11,295,928 bytes; all three native deployment fixtures and six runtime scenarios passed) |
| WASM kernel SHA-256 | `f7d9ae50e4313fb7cd45f91aac6613315f8b45f8f0f5b849131d7f465b4afda4` |

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
retain `(schema, u64 bits)` instead of repeatedly packing eight bytes. The ordinary
and raw maps are disjoint; writes/clears/pruning preserve that relation, and public
projection encodes raw entries. The byte encoding and decoding are inverse
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
anchors and helper correspondence. Mutant tests reject altered scalar behavior,
forged source/evidence or inventories, stale/missing recovery bindings, corrupted
clone mappings/cursors/work lists, overlapping scalar maps and forged table sizes
or order. Rehashing a mutant does not grant approval.

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
| Native semantic/storage suites | Kosmos safe `check-native`: 293/293 tests on the optimized sources. |
| Artifact, recovery and specialization suites | Kosmos safe `check-semantic-driver check-semantic-specialization`: 95/95 tests before the new source-mutation witness; the expanded specialization suite passes 47/47 tests. |
| Workspace comparison | Nine generated cases, 328 boundaries: independent Horos source oracle, native/WASM byte equality and alternating checkpoint producers. Exact outer restore and duplicate-custody rejection also passed. |
| Old tasks | The public Protean 5.0.0 macOS executable continued its old task after the new product was selected, preserving the original question and separate namespaces. Baseline executable SHA-256: `53471a265a095481ab9eaccf3cfc685cfa85ed243a6104db1d0e2ac166a4f935`. |
| Native owner and workspace aggregate | 172/172 tests, 29/29 build steps; 352.87 seconds including compilation on macOS. |
| Compiler scratch lifetime | Protean safe workspace suite: all 17 tests pass, including specialization with a 1 MiB request allocator. Releasing compiler/validator scratch between phases decreased maximum resident set from 8.57 GB to 3.14 GB on local runs. The separate owner suite passes 155/155 tests, 26/26 build steps in 344.53 seconds. |
| Native executable | All three deployment fixtures and five runtime scenarios passed on executable `55e50e94bfca56773ad39dbb6f728a4cdada75d7ec7f899bb9b777524c76aa79` in 692.58 seconds, including compilation under concurrent local load. Runtime groups took 429.28 and 257.57 seconds. This establishes correctness for those scenarios, not the ten-minute CI budget. The preceding product passed the same checks in 544.32 seconds. The expanded retention-query demonstration passed separately on that same `55e50e94` executable in 378.34 seconds with 88 provider calls, branch results 366/376, actual mid-clone movement, controller succession and cleanup. Its preceding polling variant took 411.28 seconds and 134 calls; these are single local measurements. |
| Linux Kosmos and optional boundaries | [Run 38978873767](https://github.com/tkersey/kosmos/actions/runs/38978873767) passed on runtime source `bd35d9c`: native owners, independent source package, source oracle, JS and browser checks. Successor `aa263f6` adds documentation, a source-mutation test and the packaged generic artifact; [run 38984858541](https://github.com/tkersey/kosmos/actions/runs/38984858541) passes the complete Linux native/source-package/oracle/JS/browser qualification. |
| Protean authoring and independent package | macOS authoring/HTTPS checks passed 52/52 build steps. Independent source-package installation for the compiler-scratch successor passed in 319.41 seconds, with matching program, assets, dependencies, compiler and target. Linux runs 38982821179 and 38985369747 passed authoring, owners, correspondence and downstream lanes; native, workspace and runtime reached the ten-minute cancellation limit. The successor still requires complete Linux qualification. |
| Packaged generic artifact | Fresh Kosmos derivation matches the retained artifact bytes; 50/50 driver tests passed. Corrupted artifact and changed-source probes fail before emitting bytes. The Protean successor build passed 27/27 steps in 143.15 seconds locally; the bound artifact emitter compiled in seven seconds. Full deployment and independent downstream qualification of that executable passed locally as recorded below. |
| Canonical guest-cut mobility | Current `c5d8dbc9` executable passes the real scripted transfer in 174.05 seconds, with 64 provider calls, a checked nonempty retention path, branches 366/376 and actual outer cleanup. The first attempt completed the behavior but failed its accounting harness because no controller transfer archive existed; the corrected harness uses the terminal export for this case. |
| Current native delivery | `check-native-placement` passes adaptive CLI and native process-placement fixtures, 22/22 steps in 143.99 seconds. All six runtime scenarios pass on the same `c5d8dbc9` executable: four general cases in 280.35 seconds, mid-clone/controller movement in 400.57 seconds and canonical guest-cut movement in 174.05 seconds. These separate runs include concurrent local work and are not additive latency or CI measurements. Independent downstream acquisition/build passes in 310.94 seconds with matching program, assets, dependencies, compiler and target. |
| Split workspace aggregate | All original 17 tests pass across the two owning roots (15 general, 2 runtime/custody), 22/22 build steps in 233.73 seconds locally. Test names are retained and the two moved runtime test bodies are unchanged. |
| Current Linux split | [Run 38986798720](https://github.com/tkersey/protean/actions/runs/38986798720) passes authoring, both workspace roots (15/15 and 2/2), correspondence and independent downstream installation. Correspondence uses the source oracle and verifies exact outer restore/duplicate custody; it does not enable WASM in that lane. Native, owners and both mobility jobs reached ten minutes. General runtime hit its 30-second result-poll timeout during specialization; the guest-mobility job separately measured about 57 seconds for that operation. No full Linux or timing pass is claimed. |
| Runtime polling qualification | The unchanged macOS `c5d8dbc9` product passes all four general runtime scenarios in 252.48 seconds with the runtime-only 120-second result-poll allowance. All scenario assertions and provider-call counts remain intact. Linux timing remains to be measured. |
| Serial reviews | Pending. |

WASM common-domain tests explicitly provide sufficient working memory for the
authored evaluator; this is a larger physical requirement than the old native
guest engine. Capacity and allocator-failure tests remain separate. Filesystem,
process isolation, OS cryptography/entropy, SQLite durability and correct operator
peer configuration remain environmental premises.

## Costs and model evaluation

The ten-family benchmark measures direct-native, generic bootstrap, generic base,
specialized base and instrumented base on dynamic inputs. It separately records
construction, independent validation, admission, start, execution, reconstruction,
restore, capsules, switching, work and allocator bytes. Kosmos
`docs/semantic-economy.md` contains the full tables and raw-output digest.

On the current local sample, generic long-cleanup execution/projection improved
from 606.166/529.813 ms to 207.957/113.325 ms. Frozen workspace binaries retained all
17 tests and reduced total test execution from 433.119 to 221.426 seconds. These
measurements exclude compilation and do not certify the ten-minute CI ceiling.

Protean CI retains a ten-minute per-job and whole-workflow ceiling. Independent
authoring, owner, workspace, correspondence and deployment work runs in separate
lanes. Runtime choices, mid-clone transfer and canonical guest-cut transfer run in
three separate lanes; their executable hashes must all match the packaged product.
The workspace aggregate retains all 17 tests in two roots, separating general
execution from runtime selection/custody. Independent lanes may restore a complete
compiler cache for the same dependency locks; native source guards still run,
and Zig decides reuse from its own inputs. Run 38988145652 restored those caches
but still rebuilt deployment binaries and exceeded ten minutes. Specialization
completed with the corrected polling allowance; deployment jobs exhausted their
remaining time during the scenarios. This is not a timing pass.

Deployment inputs now have a separate exact-match cache keyed by the entire Git
tree, compiler executable/library/license contents and modes, runner OS/architecture,
safe mode, and product/verification-peer profile. There is no prefix fallback.
Every dependency authentication, deployment scenario and independent downstream
build still runs. The cached Linux product and peer target baseline x86-64 musl.
A cache hit reuses completed compilation only; it is not previous test credit.
Any source-tree change invalidates it, including documentation and workflow edits.
This can reduce repeated qualification cost but does not improve or establish
cold-build latency. The owner aggregate retains all 155 tests and crash/reopen
checks across three independently runnable groups. Per-test stream timing of the
existing 81-test integration executable measured 142.52 seconds locally: 103.59
seconds in the 14 adaptive-controller cases and 38.89 seconds in the remaining
67 cases. These figures exclude compilation. The two integration roots retain
the original 13 fixture imports exactly once. A shared manifest helper moved
byte-for-byte to test support so using it does not also collect the other root's
tests; all assertions remain. The original aggregate still runs both groups and
the 74 support tests.
CI replaces its own prior attempt's named result artifacts when rerun, so the
terminal comparison receives the newly executed results instead of conflicting
with an earlier upload. This does not grant prior results timing credit.
Runtime result polls use the existing
120-second long-operation allowance because synchronous specialization can exceed
the short RPC default. The ten-minute limits and behavioral assertions remain.
The native fixture logs stream directly so interrupted runs retain stage evidence. The downstream script shares a nine-minute deadline across its subprocesses,
allowing up to eight minutes for cold compilation. The full portable offline demo
has a sixty-second subprocess allowance; short CLI commands retain thirty seconds.
These scheduling bounds retain every semantic assertion and still require a
passing current Linux run. Current candidate status is reported by the PR checks;
these measurements retain their original source and run attribution.

The scalar chain measured 19.346 ms generic and 18.757 ms specialized execution.
Including measured start cost leaves about 0.093 ms saved per new session;
construction, validation and admission amortize at approximately 188,690 matching
runs. The other nine families did not show a specialized elapsed-time win. Direct
native execution remains substantially faster. Specialized artifacts are roughly
18–27 MB and construction peaks are roughly 9–10 GB of requested allocator bytes;
these are not RSS measurements. Transfer and repeated restoration can erase the
small execution saving.

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

## Remaining qualification

Complete Linux
qualification within the unchanged ten-minute limit, reconcile the final proof
inventory, and run the requested serial reviews on frozen heads. The canonical
guest-cut and actual mid-clone outer-capsule demonstrations are distinct required
observations; both remain in the owning runtime suite.
