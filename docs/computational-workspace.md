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
Build references identify stored construction documents. Frozen runtime data
remains expandable for inspection, but its JSON representation is not a source
record document or component recipe and is rejected before build expansion.

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

`context.expand` on a port pages its full payload. A failed work observation
includes a `failure` reference; expanding it pages the full failure value.
Inspection previews remain bounded, and every page reports its byte range and
whether it reaches the end. If a compact value's expanded JSON length exceeds
`u64`, its automatic preview reports `{"error":"Overflow","complete":false}`
alongside the retained reference; explicit expansion reports `Overflow`.
The operation remains admitted. These reads use the existing task-owned records.

All authoritative workspace mutations commit through `workspaceCommit` or the
existing occurrence transaction. Kernel publication happens before durable
receipt transfer; failure after publication fences the owner. Receipt replay
returns the original immutable work and occurrence observation even if either
has since advanced. Ordinary workspace replies retain the inputs to their
projection: immutable content, historical work/checkpoint observations, or the
matching operation receipt. Import re-renders these replies and checks work
claims against Kosmos; a changed reply and recomputed digest are insufficient.
Initial inputs retain either the explicitly selected value's ancestry or the
constructor's empty-source hypothesis. Equal payloads cannot substitute a
different derivation across the current record and its publication history.
Scope and wait observations also use the retained event prefix. Captured native
rejections carry diagnostics only, with no result or authority references.
Applied-cancellation markers on both root and child checkpoints must agree with
the kernel's actual reason, including the outermost exit of unfinished cleanup.
Admission reads the public checkpoint graph without advancing cleanup.
Parent-wait eligibility and queue capacity are prepared before
the transaction commits. A failure while notifying a child after capture publication
fences the owner; the durable capture remains available after reopening and cannot
be dispatched again. Completed
delegated answers remain eligible for delivery after explicit task resumption.
Host shutdown preserves admitted child scheduling intent; reopening alone does
not resume execution, and explicit controller parks remain parked. Task
cancellation also reaches unfinished children after the root has completed,
without replacing its saved result. A new cancellation request after reopening
can continue already admitted cleanup.
A fresh parent cancellation also resumes cleanup explicitly parked before that
request; a later child park remains respected until another cancellation.
Cancellation may retain pending cleanup or unknown delivery. Neither is rendered
as successful disposal. Independent work is interleaved; alternative tokens stay
inside their work's checkpoint and do not imply parallel parent agents.

`workspace_instrument.zig` constructs an ordinary single-effect child only after
an explicit authorized snapshot/model delegation. Revocation is checked before
dispatch. A pending input alone creates no acquisition. Direct answers are
hypotheses, pure results have computation ancestry, authenticated source slices
have acquisition ancestry, and delegated model answers are judgments.
Import binds each completed instrument's result and answer provenance to its
actual admitted reply, including unavailable answers. A valid checkpoint alone
cannot substitute a different instrument reply.
When a model request has a byte limit, compact JSON measurement rejects oversized
selected values and port observations before their logical elements are allocated.
The final request still checks envelopes and escaping against the same limit;
this is not a general memory ceiling.

Values, sources and views have task custody as well as content identity.
Acquisition records bind the exact frozen source universe and slice; computations
retain their exact inputs, program and work. There is no cache keyed only by an
equal result payload. A new source universe cannot silently reuse an old absence
claim as evidence about that universe. `context.select` changes the next context
epoch; prepared requests remain frozen. It cannot remove policy, user messages,
active skills or action availability. Omitted evidence remains expandable.
Provenance expansion folds source references into the requested byte range,
preserving their order and multiplicity without retaining the full expanded JSON.
It still loads and validates the stored provenance metadata; paging is not a
constant-memory guarantee for all retained state.

## Acceptance witnesses

These are bounded discriminators, not a proof of arbitrary algorithm correctness.
The acceptance IDs identify the requested relationships. Owner/source inspection
is distinguished from concrete execution where it supplies the argument.

| Obligations | Executed witness / owning mechanism |
|---|---|
| AUT-01, AUT-02, AUT-03, AUT-09 | Existing ordinary offline demo and `adaptive_recovery.zig` reframing trace through actual prepared model offers; report/stop parks unfinished work. |
| AUT-04, AUT-06, AUT-08 | `workspace_programs.zig` delegates a 300-element recursive computation; a variant with no yields or ports is parked/cancelled at native quantum boundaries. |
| AUT-05, AUT-10, OWN-01 | Pure and port execution use an empty environmental registry; source/native traces finish or wait without model dispatch or mandatory alternatives. |
| AUT-07, OWN-11 | Authored waits wake for messages, selected progress, unknown delivery and definitely-not-sent results while the worker is occupied. Allocation rejection after commit cannot lose prepared parent-wait wake-up, cancellation or resumed child eligibility. |
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
| WORK-14 | Real cancellation cleanup yields, exposes a request, yields again and completes; inspection reports pending cleanup until terminal disposal. Rehashed checkpoints with a different cancellation reason reject for roots and children. Explicit parking survives older cancellation, including a later definitely-not-sent worker completion; fresh cancellation resumes cleanup. |
| CTX-01, CTX-02, CTX-08 | Partial snapshot omits a rare exception; full source expansion reveals it; a different task cannot expand the same digest. |
| CTX-03, CTX-04 | Equal payloads from different work retain distinct derivations; inline inputs and subsequent computation retain hypothesis ancestry. Coherently substituting a judgment for an inline input across all publications rejects; explicitly starting from that judgment remains valid. |
| CTX-05–07 | Adaptive context fixtures exercise view epochs, pair preservation, rejected undeclared calls, policy/user messages, skill unloading, model change and retained opaque-content rules; preparation uses immutable captures. |
| CTX-09 | Existing long catalogs/input/resources and large prompt/result tests retained; workspace source/value/view pages report completeness and coverage. First and final source pages of a billion-unit frozen input fit a 16 MiB allocator. |
| CTX-10 | Exact snapshot/resource and ancestry checks in `workspaceValueReference`, `workspaceSnapshotAccess`, archive admission and the existing profile binding; no cross-universe value cache. |
| OWN-02–07, OWN-10, OWN-14 | Delegation fixture uses the same typed input directly, from pure computation and from explicit inference; distinct occurrences, wrong callback rejection, parent amendment, pre-dispatch revocation, malformed capture and cancellation/unknown cases. Rehashed answer provenance, omitted answers and an alternative same-program checkpoint are rejected; valid unavailable answers and model/snapshot handoffs survive recovery. |
| OWN-08 | Actual SQLite write denial after kernel publication fences the owner and prevents subsequent dispatch. |
| OWN-09, OWN-12 | Frozen receipt replay after work/occurrence advancement and owner replacement, completed-answer handoff after namespace reopen, interrupted/captured build recovery, independent archive mutation, exact child/result restoration and private capture checks. Existing process-kill recovery matrix remains enabled. |
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
