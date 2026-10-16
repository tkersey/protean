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
`bd35d9c1efce6a7f690cf9aa3a05bb2eb5796beb`. The dependency lock authenticates the
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
| macOS executable SHA-256 | `1c70e7324258dd603c811780dd9c064f05301de1cceb309db0932f0657eddcd7` (11,295,928 bytes) |
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
evidence, and separate work/controller movement. The hardest scenario suspends
inside an actual progressed multi-shot clone, moves its selected instrumented
runtime, resumes both alternatives (366 and 376), then completes the real outer
cleanup. Local capsule-verifier tests alone do not establish these host laws.

## Qualification evidence

| Evidence | Result and scope |
| --- | --- |
| Native semantic/storage suites | Kosmos safe `check-native`: 293/293 tests on the optimized sources. |
| Artifact, recovery and specialization suites | Kosmos safe `check-semantic-driver check-semantic-specialization`: 95/95 tests. |
| Workspace comparison | Nine generated cases, 328 boundaries: independent Horos source oracle, native/WASM byte equality and alternating checkpoint producers. Exact outer restore and duplicate-custody rejection also passed. |
| Old tasks | The public Protean 5.0.0 macOS executable continued its old task after the new product was selected, preserving the original question and separate namespaces. Baseline executable SHA-256: `53471a265a095481ab9eaccf3cfc685cfa85ed243a6104db1d0e2ac166a4f935`. |
| Native owner and workspace aggregate | 172/172 tests, 29/29 build steps; 352.87 seconds including compilation on macOS. |
| Native executable | Pending final optimized run. Prior complete scenarios are development evidence only. |
| Linux, independent package and optional browser qualification | Pending final integrated candidate results. |
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
