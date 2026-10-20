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

The existing Service queue schedules roots, child work, controller preparation and retired-controller cleanup under one task. A work record binds the
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

## Reconstructing the active controller

Application 7 uses `protean-workspace/3` and native state writer 17. The packaged
seed is an ordinary controller artifact built through the same source constructor
as later candidates. `program.describe` with `current_controller` pages the
actual binding, epoch, program, source, interfaces and residual references.
`context.expand` reads that exact source. `controller_contract` describes the
host's admitted imports and stable task result/failure interface.

`program.build` accepts `role: "controller"` for general source records. Its entry
is `[TaskAnchor, Private]`; the controller chooses an exportable `Private` and
carry schema. Internal `controller/1/` imports bind existing owner services.
The deliberate import accepts `[proposal, carry]` and returns a response plus an
optional owner diagnostic. Construction checks exact schemas and authority,
then inserts the protected offer/model/handoff bridge and inert boot boundary.
Raw private imports, external effects and nonexportable carry are rejected.
The model can choose other evidence or reconstruction while child work waits.

Enable `tools.reconstruct` alongside the existing build/run permissions to allow
activation. `program.adopt` names the successor and a pure converter, the
`expected_controller_epoch` and `expected_handoff_identity` from the protected
request overlay, an optional trial selection, and a reason. The converter takes
`[carry, OwnerView]` and returns the successor's private input. OwnerView freezes
the real task input, ordered user amendments and published child observations.
A trial reference is supporting information; it never replaces conversion.

Only the owner commits activation. The new checkpoint reaches construction-owned
`boot_ready` before receiving live authority. A transaction changes the binding
and advances the controller epoch once. Task identity, original inputs, child
identities, evidence, costs and event history remain. A later return to old code
uses a new forward conversion; it cannot restore old task facts. Receipt replay
precedes current-epoch checks. Instruction or cancellation changes during
preparation invalidate activation, while independent child progress remains.

An operator can call `task.adopt` with a stable `client_operation_id`, `task_id`,
`expected_revision` and the same `adoption` value. Task status exposes
`controller_epoch` and `controller_handoff` for this request. The owner can force
a park at a protected model or handoff request with valid carry and known delivery.
Unknown or active dispatch and unavailable private-state translation block recovery.
Conversion uses current owner facts; failed operator preparation leaves the old
controller parked. Replaying the same operation returns its original admission.

The superseded execution becomes a residual under its original image. It may
only unwind qualified cleanup. Inspect residual references through `work.inspect`
and use `work.park`, `advance` or `cancel` with their execution/control revisions.
Retained observations preserve the published cleanup state at their event cut.
Unknown delivery remains unresolved and cannot be reinterpreted as completion.
Root completion does not imply that residual cleanup is complete. The existing
reconciliation API handles an unknown residual occurrence using its real binding.

A controller `work.start` requires an explicit `trial` binding. Synthetic bindings
name exact typed payload/response pairs and a frozen task view. Unseen requests
remain unavailable. Optional live inference requires `live_inference: true` and
the ordinary inference grant; actual calls are charged to the task. Trial
adoptions remain proposals, trial outputs retain trial provenance, and synthetic
answers never become acquired evidence. Trials cannot issue live root commands.
Explicit trials progress through `work.advance` or `work.pump`; changing their
continuation policy can admit owner scheduling. Each trial reply publishes its
occurrence with the work observation, including before the next evaluator step.
An explicit trial parks after that host reply; a fresh `advance` or bounded `pump`
consumes it. Host settlement does not grant an additional evaluator quantum.

Behavioral succession and controller movement advance one authority lineage.
Frozen movement excludes activation; preparation excludes a controller move.
Signed behavioral transitions precede later remote commands through the existing
peer path. Child custody and evaluator realization revisions remain independent.
BPI3, PST3, ERQ3, ERS3 and PKO3 retain their existing meanings. Old tasks require
their original executable and namespace contract; upgrading the installed binary
does not rewrite their checkpoints. No live-model improvement is claimed.

## Acceptance witnesses

### Optional runtime inspection

`program.specialize` derives a checked runtime for an admitted guest program.
Its `origin_program` names the first source artifact used to admit that runtime;
`guest` identifies the exact compiled guest image. Distinct task-owned sources
with that same image can share the runtime, while each work item retains its own
source, exposed ports and authority. Copying runtime bytes grants no task custody.
`work.start.runtime` selects that runtime or the packaged generic evaluator.
`work.realize` switches at the exact execution, control and realization revision;
the guest checkpoint and execution revision stay fixed. `work.request_cut`
publishes either a guest cut or an outer execution capsule. These operations are
optional and never grant environmental authority.

`context.materialize` accepts `guest_view` with an expected work revision,
realization revision, and `nodes` scope (`all` or selected numeric node IDs).
The task owner authorizes metadata from that task's own work. The result includes
reference and ownership edges, roots, node kinds and available block/activation
positions. It includes no guest payloads, blob contents or source text. Numeric
node IDs describe one checkpoint; they are not continuation handles.

The `inspection` derivation retains the exact work publication, checkpoint,
runtime code and node scope. Access reconstructs the value from that publication;
archive validation checks its journal and runtime dependencies. A partial view
does not claim graph completeness. A later request may select another scope.
Materializing or querying a view does not advance the inspected work.

The native controller also advances in bounded physical steps. Its guest
execution revision changes only when a guest cut is published. Parking,
eviction, export, or placement retains an unfinished operation as an outer
capsule with its exact accepted control. Recovery resumes that operation before
applying newer cancellation intent; an acquired response is consumed once.

### Optional native placement

`placement.sites`, `inspect` and `assess` expose operator-admitted peers and
retained custody/cut facts. `placement.move` selects a peer name, an independent
controller or work subject, an operation name and the expected custody epoch.
The native owner captures the cut, signs and retains the action, freezes that
subject, then stages its complete archive over the configured peer channel.
An exact outer capsule includes its selected runtime artifact; that artifact
does not have to be preinstalled at the destination.

The configured command opens an owner stdio session. Access to that session
grants the full owner API, including unsigned local placement operations.
Operators must restrict process launch and stdio access to trusted owners;
the signed peer handshake does not authenticate or restrict a stdio client.
Peer replies are parsed as responses and cannot call back into the launching
owner's API.

The launch option `--placement-config FILE` reads this operator-owned shape:

```json
{
  "signing_key_file": "/private/site-key.hex",
  "transport_directory": "/private/placement-spool",
  "staging_limits": {"bytes": 1073741824, "files": 16},
  "peers": [{
    "name": "worker",
    "public_key": "<64 hexadecimal characters>",
    "namespace": "<64 hexadecimal characters>",
    "native_build": "<64 hexadecimal characters>",
    "compatibility": {
      "base": "<64 hexadecimal characters>",
      "admission": "<64 hexadecimal characters>",
      "bridge": "<64 hexadecimal characters>",
      "semantics": "<64 hexadecimal characters>",
      "private_state": "<64 hexadecimal characters>"
    },
    "resource_binding": "<64 hexadecimal characters>",
    "disclosure": {"allow_private": true},
    "command": ["/approved/protean", "serve", "--transport", "stdio",
                "--offline", "--state-dir", "/private/worker",
                "--placement-config", "/private/worker.json"],
    "remote_name": "controller",
    "timeout_ms": 30000
  }]
}
```

The seed file contains 32 bytes as hexadecimal and must be owned by the current
user with no group/other permissions. The spool must already exist as a private
directory outside the execution namespace. Keys and command paths are launch
inputs; they never enter model actions or transferred archives. Native
`placement` RPC requests `identify` and `compatibility` expose the actual site,
build, resource and subject profile identities used for operator pinning.
Disclosures default to denied. Optional `denied_objects`,
`maximum_object_bytes` and peer `archive_limit` constrain the actual retained
closure, including code, constants, runtime metadata and observations.
Optional `staging_limits` bounds aggregate incoming archive bytes and file count
under the spool lock. Omission imposes no application quota; filesystem capacity
remains the limit. Durable acceptance or refusal retires the staged archive and
the source transport copy. Restart completes interrupted retirement from retained
decisions, while undecided transfers preserve resumable bytes.

`placement.retry` continues a retained transfer. `placement.withdraw` cancels an
unsent transfer locally or asks the destination for its signed decision. A lost
reply or a disconnected process never releases frozen source custody. If the
destination already accepted, withdrawal returns that acceptance. Reusing the
same operation with changed parameters rejects. Imported copies cannot activate
serialized local or frozen custody, even if the tags name the receiving site.
Omitting those tags or disabling placement configuration grants no execution:
fresh local admission belongs to the namespace and is never exported. Only the
subject verified by bilateral acceptance becomes local. Other copied subjects
remain remote, including a child frozen before its controller moved; signed
executor succession resolves its eventual destination.
Freezing retains the complete archive manifest in the source transaction.
Other locally owned work may progress afterward without changing that export.
The retained export is a source obligation and is excluded from transferred
archives. Replaying an offer still checks the current runtime, peer profile,
size limit and disclosure policy.

`placement.control` sends a revision-bound work command to the current executor;
`placement.expand` requests a page from that executor. Signed controller
succession accompanies controls after controller movement. Returned references
remain remote references and do not become locally owned values or selected
views. Remote reply observations preserve the original signed response.
If work moves onward, the previous executor returns its signed bilateral
succession proof. The controller verifies each transfer, updates its directory
and sends the original command to the configured successor. A retained report
from an earlier executor remains an exact receipt; it is not fresh progress at
the successor. Cached messages and newly routed messages require current
disclosure admission before transmission.

Parent cancellation uses signed executor observations to cancel and pump
separately placed work. Completion requires a terminal executor observation
with cleanup complete. An unresolved control or unavailable transport remains
incomplete; a stale local work copy cannot certify remote cleanup. A fresh parent
cancellation after reopening retries an unanswered idempotent control whose
transport has not recorded a failure. Recorded failures require explicit retry
or reconciliation.
Each automatic cleanup request names the controller's durable cancellation
event. A later explicit executor park remains parked until a fresh cancellation
request. Cancellation remains an owned obligation while custody is frozen and
resumes when an abort or refusal restores local custody. Cancel-mode shutdown
drains active placement transport within its existing deadline and reports
unresolved cleanup as incomplete.

Destination admission currently requires an empty task namespace. Placement
does not merge independently advancing task archives. Acceptance retains the
continuation without automatically resuming it; an explicit native resume or
remote work command selects subsequent execution. The subprocess channel closes
after the signed response, so long-running remote execution needs a continuing
native owner. The protocol preserves custody across that process lifetime.

`program.describe` sections `retention_query` and `divergence_query` return
ordinary Horos source records for building reusable query programs. The retention
input is a view and target node. The divergence input contains two finite traces
with explicit bindings and completeness. Results distinguish partial absence,
observed finite agreement and incomparable controls. Preserve the view references
in `context.materialize.sources` when constructing a query input, then start the
query from that value reference so its result retains the inspection ancestry.

These are bounded discriminators, not a proof of arbitrary algorithm correctness.
The acceptance IDs identify the requested relationships. Owner/source inspection
is distinguished from concrete execution where it supplies the argument.

| Obligations | Executed witness / owning mechanism |
|---|---|
| C01–C06 | The shared A → B → A fixture builds general source, changes private representation and traversal, preserves the held child and amendment, and checks active source, protected offers, stale authority and receipt replay. |
| C07–C09 | Variants of that fixture reject failed, malformed and interrupted conversion, invalidate stale instruction/cancellation cuts, and retain completed or unresolved predecessor cleanup under its original binding. |
| C10 | The existing crash harness kills and reopens the same succession before activation, at commit uncertainty and after publication; the operation and controller epoch remain singular. |
| C11 | The shared continuity fixture runs isolated trials, rejects unseen request pairs and authority escalation, and checks distinct trial provenance. |
| C12 | The packaged runtime mobility trace builds and adopts a controller, survives a process kill, reads the active source, then transfers that controller and finishes its existing remote child's cleanup. |
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
recompile to identical BPI3 before execution. Qualification runs the workspace
test roots, imported product modules and shipped native executable in Safe mode.

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
