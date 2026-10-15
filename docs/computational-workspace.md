# Model-directed computational workspace

The adaptive controller can construct a parameterized Horos program, run it on
independent inputs, retain unfinished work, answer a typed port, or explicitly
delegate an interpretation. Its ordinary actions remain available while a child
waits. The controller can leave the question unanswered and pursue another
method. This is a capability, not a prescribed investigation sequence.

The canonical model interface is `program`, `work`, and `context` in
`src/workspace_contracts.zig`. Short action examples and port/policy observations
are in [the application guide](../examples/adaptive/README.md#construct-and-retain-computations).
The previous `tool_build`/`tool_run` action route is retired in this image.
Component recipes remain an input to the shared program build owner.

## Construction and authority

`runtime/native/source_records.zig` derives a versioned transport from the linked
Horos records. It carries no callbacks. Strict decoding and
`source_preflight.zig` check fields, indices, forward dependencies, and unused
declarations before Horos's source checker/lowerer. `program_construction.zig`
rejects raw protected and external identities. Model-selected exposures cause
`workspace_driver.zig` to construct ordinary typed handlers; the compiler still
checks captures, regions, cleanup and linear/multi-shot use. Explicit capability
attachments retain their identities. Repeated alternatives instantiate a real
resumption rather than copying or restarting the whole work item.

`dynamic_values.zig` projects actual canonical descriptors. Integer/byte/text
conversion does not infer types from JSON shape. Internal computations,
capabilities, cells and resumptions cannot cross this export boundary.
Program admission does not certify that an algorithm answers the user's question.

`workspace_build.zig` runs compilation on the existing worker using immutable
inputs. The worker owns neither Store nor Resident. The Service validates the
capture and publishes the program, schema/source/image closure and operation
receipt in one transaction. Same-image recompilation establishes exact image
identity; behavioral comparison never substitutes foreign request digests.

## Retention, effects and context

The existing Service queue schedules `(task, work?)`. A work record binds the
program/input, Kosmos checkpoint, execution/control revisions and run policy.
The existing occurrence engine binds external delivery to that exact subject.
An optional driver port exposes a typed command, not a raw stack or settlement
capability. Ordinary Horos BPI3 admission and program-relative PST3 restoration
remain separate checks.

All authoritative workspace mutations commit through `workspaceCommit` or the
existing occurrence transaction. Kernel publication happens before durable
receipt transfer; failure after publication fences the owner. Receipt replay
returns the original immutable observation even if work has since advanced.
Cancellation may retain pending cleanup or unknown delivery. Neither is rendered
as successful disposal. Independent work is interleaved; alternative tokens stay
inside their work's checkpoint and do not imply parallel parent agents.

`workspace_instrument.zig` constructs an ordinary single-effect child only after
an explicit authorized snapshot/model delegation. Revocation is checked before
dispatch. A pending input alone creates no acquisition. Direct answers are
hypotheses, pure results have computation ancestry, authenticated source slices
have acquisition ancestry, and delegated model answers are judgments.

Values, sources and views have task custody as well as content identity.
Acquisition records bind the exact frozen source universe and slice; computations
retain their exact inputs, program and work. There is no cache keyed only by an
equal result payload. A new source universe cannot silently reuse an old absence
claim as evidence about that universe. `context.select` changes the next context
epoch; prepared requests remain frozen. It cannot remove policy, user messages,
active skills or action availability. Omitted evidence remains expandable.

## Acceptance witnesses

These are bounded discriminators, not a proof of arbitrary algorithm correctness.
The acceptance IDs identify the requested relationships. Owner/source inspection
is distinguished from concrete execution where it supplies the argument.

| Obligations | Executed witness / owning mechanism |
|---|---|
| AUT-01, AUT-02, AUT-03, AUT-09 | Existing ordinary offline demo and `adaptive_recovery.zig` reframing trace through actual prepared model offers; report/stop parks unfinished work. |
| AUT-04, AUT-06, AUT-08 | `workspace_programs.zig` delegates a 300-element recursive computation; a variant with no yields or ports is parked/cancelled at native quantum boundaries. |
| AUT-05, AUT-10, OWN-01 | Pure and port execution use an empty environmental registry; source/native traces finish or wait without model dispatch or mandatory alternatives. |
| AUT-07, OWN-11 | Authored wait fixture wakes through the inbox/control path while worker capacity is occupied; pure work remains eligible. |
| BUILD-01, BUILD-02 | Novel GCD on two inputs; recursive schema/list traversal across more than 300 boundaries, plus independent source/native execution. |
| BUILD-03, BUILD-04, BUILD-05 | Source transport, unused malformed declaration, index/order, protected identity and nested action rejection fixtures. |
| BUILD-06, BUILD-08 | Existing component recipes use the shared worker/owner; actual controller traces revise rejected construction without losing ordinary offers. |
| BUILD-07 | Source compilation allocation fault sweep checks released owners; cancellation admits no program; interrupted build restarts as pure work. |
| BUILD-09 | Independent scalar codecs, malformed/unsupported values, deep recursive projection and allocator-failure fixtures in `dynamic_values.zig`. |
| BUILD-10 | Packaged native peer constructs and reuses programs inside existing OS execution boundaries; downstream installation builds authenticated dependencies independently. |
| WORK-01–05 | Actual retained work/port restart, repeated operations, stale/conflicting answers, inspection and exact receipt observations in `workspace_programs.zig`. |
| WORK-06–08 | Prefix 101 occurs once; actual multi-shot inputs 10/20 yield 111/121 with mutable aliases preserved within each branch and isolated across branches; exclusive capture rejects. |
| WORK-09, WORK-10 | Independent source/native/WASM fixtures preserve distinct attachments, shallow behavior and explicit successor-state capabilities. |
| WORK-11 | Ordered collection includes repeated, completed, cancelled, pending and missing identities without cloning the parent. |
| WORK-12, WORK-13 | No image-replacement operation exists; records bind exact admitted program/checkpoint. Ordinary quantum control is separate from generation-bound port commands; stale/no-port controls reject. |
| WORK-14 | Real cancellation cleanup yields, exposes a request, yields again and completes; inspection reports pending cleanup until terminal disposal. |
| CTX-01, CTX-02, CTX-08 | Partial snapshot omits a rare exception; full source expansion reveals it; a different task cannot expand the same digest. |
| CTX-03, CTX-04 | Equal payloads from different work retain distinct derivations; inline inputs and subsequent computation retain hypothesis ancestry. |
| CTX-05–07 | Adaptive context fixtures exercise view epochs, pair preservation, policy/user messages, skill unloading, model change and retained opaque-content rules; preparation uses immutable captures. |
| CTX-09 | Existing long catalogs/input/resources and large prompt/result tests retained; workspace source/value/view pages report completeness and coverage. |
| CTX-10 | Exact snapshot/resource and ancestry checks in `workspaceValueReference`, `workspaceSnapshotAccess`, archive admission and the existing profile binding; no cross-universe value cache. |
| OWN-02–07, OWN-10, OWN-14 | Delegation fixture uses the same typed input directly, from pure computation and from explicit inference; distinct occurrences, wrong callback rejection, parent amendment, pre-dispatch revocation, malformed capture and cancellation/unknown cases. |
| OWN-08 | Actual SQLite write denial after kernel publication fences the owner and prevents subsequent dispatch. |
| OWN-09, OWN-12 | Receipt replay after replacement, interrupted/captured build recovery, independent archive mutation, exact child/result restoration and private capture checks. Existing process-kill recovery matrix remains enabled. |
| OWN-13 | Prior application parked at a question, temporary installation retains its exact binary, and the old task completes through that retained runtime. |

Historical independent byte fixtures are retained. Replaced old tool-action tests
now exercise the new canonical actions, with the same large catalog, reuse,
authorization and recovery obligations. Current generated sources additionally
recompile to identical BPI3 before execution. The two workspace test/emitter roots
use Debug because Zig 0.17's Safe optimizer crashes compiling those roots;
imported product modules and the shipped native executable retain Safe mode.

## Qualification and measurements

Run the repository's normal `zig build check-protean check-native -Doptimize=safe`.
The workspace source oracle is included in `check-native`. Add
`-Dworkspace-wasm=/absolute/path/to/kosmos-kernel.wasm` for native/WASM equality
and producer switching. The latter share an evaluator and are not independent
semantic implementations; Horos's source oracle is the independent comparator.
It covers the GCD, recursive list, pure/mutable alternatives, shallow, successor
and attachment fixtures, not arbitrary source or environmental delivery.

An Apple-silicon local run measured 304 boundaries for the yielding 300-element
list, 940,376 cumulative checkpoint bytes and a 3,540-byte maximum checkpoint.
The two-alternative mutable fixture used five boundaries, 841 cumulative
checkpoint bytes and a 223-byte maximum. Every case had zero controller/delegated
inference calls. Timing varies with compiler/host and native process startup;
the check prints actual compiler, arena, native and WASM measurements per run.

The [evaluation runner](../tools/evaluation/README.md) freezes three workload
families and three arms, records actual costs, and leaves quality adjudication
explicit. No live model efficacy or token-saving percentage is claimed.

Application 5.0.0, context v7, output v5 and native state format 13 require a new
namespace. Current pins are Horos `931b960723fb8a2b6808d0c53e2e18efe8394c92`
and Kosmos `f38b077f78e39267c05207393d4043b053187e81`. `describe-build` records
the exact compiler, image, package and executable hashes for each platform.
The [retaining installer](native-single-binary.md#saved-state-and-portability)
ships with qualification archives. It never migrates old continuations or edits
their namespace. Building/qualifying this feature does not update an installed
runtime, merge a PR or publish a release.
