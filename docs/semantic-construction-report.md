# Model-directed semantic construction

This implementation extends exact semantic-source inspection, authorized
observations, isolated interpretations, and generated runtime construction through
the existing workspace owners. The public contract is
[Computational workspace](computational-workspace.md).

Current observer ownership is part of the existing Task and Work records. The
Task names current subscription heads; each predecessor names its successor.
Starting a continuation publishes both records atomically, without changing the
observed source work. The continuation owner requires local custody of its
predecessor before updating it. Earlier fold snapshots remain immutable historical
observations. Archive admission reconstructs the head and successor relationships
from publications before trusting the current records.
Completed predecessor snapshots also reconstruct the canonical observation used
to check both sides of succession. This preserves archive closure when the
scheduler completed the predecessor without an explicit operation receipt.
Work observations expose predecessor and successor work references, so a caller
can follow its subscription to the current fold and stop it using the returned
revisions. The same projection serves inspection, collection, wait and controller
views; historical snapshots retain the links known at their publication.

Every Work write normalizes its outer cursor from the last capsule identity.
Null and repeated capsules preserve the cursor; a changed capsule advances it.
The cursor retains an identity, not another capsule retention root. Live observer
queries visit current heads and use that cursor. Historical validation reconstructs
cursors independently from capsule publications. Live inspection, collection,
wait and controller views share a request-local index of active lossless heads.
The index records a common consumed revision per source and checkpoint level;
unconsumed or differing revisions block advancement. Historical projections
explicitly use independently replayed history, including at the current watermark.
One validation owns one compact timeline per task: consumed-revision requirements
are indexed by source and checkpoint level, and outer cursors by source. A read
selects observer membership at its own event cut and the source cursor at the
snapshot's watermark. Event payloads are decoded and released during one ordered
scan; historical queries retain no decoded event prefixes. Standalone historical
reads scan only through their requested cut.

In the existing native observer fixture, source advancement after 4, 8 and 16
retained folds reads 5 Work records in each case, compared with 28, 49 and 78
before the change. Inventory queries fall from five to zero. The outer-observer
fixture performs no event-history query during live advancement. These are
operation counts for the measured paths, not end-to-end latency claims.
Live inspection, collection and wait after 4, 8 and 16 folds now scan zero event
rows, compared with 18, 30 and 54 rows per request before this repair. Stopped
subscriptions, simultaneous consumed revisions, and both checkpoint levels retain
their blocking behavior. Archive validation shares one snapshot-validation owner
across provenance, captured projections and record bodies. Its observer index
retains scalar changes proportional to publications and works, shared across
distinct read cuts. Independent publication and controller checks remain in the
archive verifier. The index lives only for one validation invocation; no facts
survive into another invocation and no persistent cache is added.

The existing archive fixture captures 4, 8 and 16 additional reads of unchanged
work, with a real observer active and then stopped. One native macOS Safe run of
each implementation gives the following comparison against `0ed1b2c`:

| Additional reads | Retained events | Observer scans before/after | Decoded observer rows before/after | Validation allocation peak before/after |
|---|---:|---:|---:|---:|
| 4 | 363 | 9 / 1 | 2,772 / 363 | 152,156,179 / 57,772,139 bytes |
| 8 | 387 | 13 / 1 | 4,304 / 387 | 261,255,281 / 54,147,181 bytes |
| 16 | 436 | 21 / 1 | 7,665 / 436 | 149,896,099 / 34,098,705 bytes |

Allocation peaks count requested bytes above live allocation at validation entry,
not process RSS. Arena growth makes these whole-validation peaks nonmonotonic.
The fixture has four earlier replies, so the total reply counts are 8, 12 and 20.
Independent archive scans still decode 52,325, 52,373 and 52,859 rows in both
implementations. These measurements establish reduced observer-history work and
allocation for this fixture, without claiming constant total archive cost or an
end-to-end speedup.

Historical semantic descriptions retain the policy facts used to render their
pages. Later policy changes affect new descriptions and execution eligibility,
while old replies remain reproducible through export and import. Scheduler
pumping treats current semantic or guard-policy denial as a local blocked step;
ordinary control and unrelated work remain available. Explicit operations retain
their policy errors, and cancellation retains its cleanup authority.
Reopening compares frozen application settings using the original semantic-policy
snapshot while admitting the explicit current policy separately. The retained
profile bytes and resource identity remain unchanged.

Guard creation and archive admission share the same initial state. A new guard
has no accumulated agreement evidence; only completed comparisons advance that
history.

New mutable semantic-source materializations and direct derivations bind their
read cut to the preceding journal position. Compiler attempts publish their
attempt and occurrence at that read position before dispatch. Archive admission
requires exactly one matching binding. The attempt retains the suspended
checkpoint that produced its request; admission checks it against the request's
state digest and the journal's controller/checkpoint at that position. Delayed
completion keeps the original read cut. Existing immutable values and operation
replays retain their historical provenance.

Root guest publications and controller activations establish the execution
ordinal in the existing event stream. Each retains compact before/after
checkpoint and controller commitments; intermediate checkpoint objects are not
retained by these commitments. Archive validation checks their continuity and
derives read-cut ordinals from the publications and the final task. A retained
suffix reconciles its omitted prefix against that endpoint. Realization commands
and receipts must match the resulting cut, historical epoch, and realization.
Captured construction attempts supply their read cuts to the same ordered pass.
Matching an attempt to its frozen input is insufficient without the corresponding
root ordinal at that exact watermark.
The native witness rejects a coherently rehashed command, receipt, and read cut
while admitting an earlier selection after later execution progress. This checks
archive consistency; it does not authenticate an arbitrarily rewritten unsigned
history. Native state format 20 requires the publication evidence, while older
namespaces retain their compatible executables.

Live controller offers use the task's retained runtime and realization revision
when their event cut, controller binding and epoch are current. Earlier cuts
still reconstruct history, and archive validation independently checks the
current runtime against its publications. In the existing controller witness,
one offer after realization at nine retained events previously scanned and
decoded all nine events; it now performs zero such scans and decodes. This is an
operation-count result, not an end-to-end latency measurement.

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
workspace contract 4, and native state format 20 retain historical executable
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
measure three matching cuts after restarting the owner. Construction and
validation are separate from continuation, publication, and inspection. The first
continuation includes reconstruction, execution, and publication; it is not an
isolated restore measurement. Requested Zig backing allocation is measured from
a retained baseline, separately from RSS. Logical artifact/reference byte counts
are not deduplicated disk footprint. No break-even or universal speedup follows
from these finite measurements.

The [evaluation runner](../tools/evaluation/README.md) supplies matched real-model
comparison conditions and retains unsuccessful work. Its semantic preflight
prepares nine cases without inference. Independent model discovery and efficacy
remain unmeasured.
Archive export receives the run's approved configuration, preserving current
semantic-policy checks when measuring retained candidate work. Arm classification
treats observer creation as guest-view use, including placement-routed controls.

## Integrated inputs and qualification

The selected dependency tuple uses Horos
`f60b116b170d8e175db440095fb4d60384aa90bd` and Kosmos
`c6de0fa718ab322c53127db7e8fd3fb3197837a7`. Their published GitHub archives were
independently downloaded and matched against complete committed source
inventories. Native dependency setup authenticates those same inputs.
Protean builds on accepted controller reconstruction
`2e40ce45d0f4b9b2ee81838386d5f1e0693ea228`.

Exact-commit qualification and review results are recorded in
[Horos #177](https://github.com/tkersey/horos/pull/177),
[Kosmos #74](https://github.com/tkersey/kosmos/pull/74), and
[Protean #59](https://github.com/tkersey/protean/pull/59). Protean's existing native
roots cover owners, workspace execution/history/retention, selection, succession,
custody, source correspondence, packaged control/runtime/placement, and downstream
installation. The selection lane requires all seven selected tests. The nineteen
Linux lanes and aggregate qualification retain their 600-second limits.
Interrupted or failed checks provide no passing credit.

Compiled qualification artifacts bind their complete source, dependency lock,
toolchain, effective target, environment and recipe. Linux x86-64 artifacts use
the build graph's explicit baseline CPU; native macOS artifacts also bind Zig's
reported native CPU model and features. Matching artifacts may be reused;
missing or invalid entries are rebuilt. Every selected test executes on a cache
hit. There are no separate cold/warm runs or manual cache-disable switch.
Product delivery envelopes separately bind the current commit and workflow run.

## Acceptance coverage

The acceptance obligations extend the existing roots; they do not create new
lanes or one test module per obligation. The final qualification status above
applies to this entire mapping.

| Obligation | Existing deciding owner and observation |
|---|---|
| AC-01 | Kosmos driver and Protean workspace inspection: selected source, helpers, derivation and paging retain exact identities. |
| AC-02 | Kosmos views and Protean context materialization: denied values remain omitted and partial disclosure retains its scope. |
| AC-03 | Protean workspace/event witnesses: authored observer folds retain cursors, report gaps and survive restart without duplicate folding. |
| AC-04 | Kosmos analysis and Protean shared construction: multiple assumptions and resumable branches have no live acquisition authority. |
| AC-05 | Protean custody: the same ordinary generated producer executes twice on distinct source inputs and produces independently checked candidates. |
| AC-06 | Horos source/recovery and Kosmos driver/specialization: valid scalar, helper and private-layout changes execute through recovery. |
| AC-07 | The same source/candidate witnesses reject well-typed wrong edits, roots, scopes, helpers, layouts and anchors, including exhausted checks. |
| AC-08 | Kosmos realization and Protean runtime selection: retained guest switching and switch-back preserve requests, state, identities and cleanup. |
| AC-09 | Kosmos capsule tests: unfinished execution requires its exact realization and helpers, separately from a portable guest cut. |
| AC-10 | Protean guarded execution: reference ownership blocks a well-shaped divergent successor before external dispatch; agreement remains finite evidence. |
| AC-11 | Existing occurrence, recovery and cancellation roots: acquired replies settle once and candidate failure cannot prevent reference cleanup. |
| AC-12 | Existing controller/runtime intersection: current root epochs govern targeting and unrelated succession preserves existing work lineage. |
| AC-13 | Protean custody/placement: validated dependencies travel through one existing peer path; trust, disclosure and unsupported guard modes reject. |
| AC-14 | Existing Store and workspace replay/import tests: duplicate and stale operations cannot create execution ownership or checker authority. |
| AC-15 | Existing native workflows, package consumers and this report: preserved substantive coverage, input-keyed compilation reuse, every selected test executed, 600-second job/aggregate ceilings and disclosed costs. Current exact-head qualification is recorded in Protean #59; earlier passes do not qualify changed inputs. |
| AC-16 | Existing native operation and evaluation runner: ordinary tools remain available, comparison preflight is runnable and paid inference is excluded. |

## Footprint

The comparison bases are Horos `ae8ace5`, Kosmos `6c70d24`, and accepted Protean
`2e40ce4`; measured sources are `f60b116`, `c6de0fa`, and the Protean
observer custody and temporal-history successor of `0ed1b2c` respectively.
Added/deleted byte counts include newlines in dedicated test files and inline
test blocks. Helpers outside those blocks are excluded from this test-only
measure; the complete Zig totals below include it. Git diff counts can include
moved lines as additions and deletions.

| Repository | Changed test files | Added bytes | Deleted bytes |
|---|---:|---:|---:|
| Horos | 14 | 133,296 | 213 |
| Kosmos | 11 | 142,798 | 1,104 |
| Protean | 24 | 570,148 | 164,015 |
| Total | 49 | 846,242 | 165,332 |

Complete changed Zig source adds/deletes 393,020/67,052 bytes in Horos,
326,159/20,796 in Kosmos, and 927,972/208,238 in Protean. No test modules,
directories, executables, CI lanes or checked-in trace banks were added. The
largest test-file extension is Protean's existing `workspace_runtime.zig`:
402,242 added and 111,958 deleted bytes. Its two generated productions are reused
by activation, five-arm measurements, recovery and mobility. Historical
independent byte fixtures remain unchanged.

The packaged semantic core is 275,293 bytes, SHA-256
`eebde9b99c1144848a558b7ff1f863f31614d0fd403418cbfa813d878f25b895`.
Regeneration binds the selected Kosmos source and Horos package.
Generated candidates use `kosmos.semantic-artifact/3` and
`kosmos.source-relation/1`; historical artifacts retain their existing family.

## Cost measurements

Native macOS fixture experiments use exact Zig 0.17.0 Safe. Reuse and downstream
comparisons use the same product from `f6f26d3`; custody compares the unchanged
`7524106` fixture with Kosmos `6aec3c7` against that fixture with `deeab8d`.
Each whole-fixture row below is one before/after sample with no other heavy
qualification running. These observations do not establish Linux savings.

| Fixture | Before seconds | After seconds | Preserved deciding observations |
|---|---:|---:|---|
| Retained-program reuse | 118.30 | 80.54 | A before restart, B/A/B afterward; both inputs, repeated reuse, provenance, archive accounting and historical quota boundaries. |
| Independent installation | 394.96 | 365.57 | Public acquisition/build/install, both tamper rejections, interpreter isolation, exact build identity, installed-program progress and settled cancellation. |
| Custody execution | 224.594 | 205.752 | Both generated transformations, validation, retained-work activation, migration, cleanup and all five comparison arms. |

Reuse performs four computations and 29 provider calls, down from twelve and 43.
Two repeated input materializations retain the former evidence-quota discriminator;
the existing workspace owner separately starts 256 work items. Protocol-version
and retired-state rejections run once in the controls group. Three isolated
prelude samples saved about 0.10 user-CPU seconds each, with no reliable elapsed
improvement. Per-group deployment isolation, tracing and identity checks remain.

The installed execution check takes 0.428 seconds, replacing a duplicated
35.282-second demo; the complete fourteen-call demo still runs in controls.
Installation build time was 299.393 versus 304.848 seconds. The shorter witness
does not account for build-time variation. A 30-second total execution budget is
also bounded by the existing Linux installation deadline.

The first custody transformer performs 3,384 guest transitions and fourteen
publications instead of 6,798 and 27; it takes 76.447 versus 86.292 seconds.
The reused transformer retains 1,045 transitions and five publications and takes
20.519 versus 20.636 seconds. Both input and result sizes are unchanged.
Full custody build-and-test time is 345.61 versus 365.50 seconds, while peak
command RSS rises from 6,186,156,032 to 6,632,669,184 bytes. The collector removes
duplicate searches and permits idempotent row visits; duplicated synthetic input
can require more work, so no universal producer speedup is claimed.

Sharing immutable preparation across the six invalid-output cases would save at
most about 0.12 seconds: all six preparations together measured 0.144 seconds.
Those independent mutable fixtures remain unchanged. The full-table layout
traversal experiment exceeded 600 seconds and was discarded. Lane partitioning,
native platforms, isolation, tracing and 600-second job/aggregate limits remain.

The following single native macOS sample uses committed Protean `c1e2ffb`, Horos
`f60b116` and Kosmos `6aec3c7` with the shared witness and exact Zig 0.17.0 Safe.
Custody passes all eighteen build steps and its complete scenario in 354.26
seconds, rebuilding the test binary with four other compiler steps cached and
executing the test. No other native qualification job ran alongside it. Process
peak RSS is 11,388,616,704 bytes. This does not discharge Linux qualification.

The generated producer executes on 1,321,173 and 1,321,177-byte source inputs,
returning 1,807,351 and 1,204,897 bytes in 84.697 and 20.505 seconds. Both outputs
undergo independent validation. Their executions perform 6,798 and 1,045 guest
transitions, preserving the same 256-transition quantum. First-candidate
construction takes 86.929 seconds, independent validation 0.758 seconds and
producer build 0.006 seconds. Built-in specialization plus validation takes
10.456 seconds; instrumentation plus validation takes 10.454 seconds. These are
instrumented finite observations, not model efficacy or speedup claims.

| Arm | Three-cut continuation ms | Publication ms | Artifact bytes | Evidence bytes |
|---|---:|---:|---:|---:|
| Generic | 39.391 | 7.663 | 275,293 | 51,808 |
| Built-in specialized | 4,013.031 | 47.047 | 27,144,060 | 23,450,911 |
| Generated validated | 792.257 | 8.796 | 721,836 | 498,044 |
| Instrumented | 4,160.363 | 47.615 | 27,145,721 | 23,452,349 |
| Reference guarded | 580.323 | 8.127 | 997,129 | 549,852 |

All five arms perform 21 guest transitions and publish 550 logical guest
checkpoint bytes. Instrumentation retains 389 trace bytes. The guarded arm
spends 28.343 ms in reference execution and 17.989 ms in candidate execution;
its guard capsule is 20,232 bytes and its candidate proposal is 5,902,036 logical
bytes. These logical sizes do not measure deduplicated retained disk space.

| Arm | Owner restart ms | First continuation including reconstruction ms | Backing baseline bytes | Peak above baseline bytes | Live backing at end bytes |
|---|---:|---:|---:|---:|---:|
| Generic | 137.045 | 15.315 | 349,688,508 | 898,191 | 349,999,680 |
| Built-in specialized | 139.760 | 3,975.332 | 349,688,508 | 4,302,829,242 | 484,214,886 |
| Generated validated | 141.875 | 767.393 | 599,672,266 | 2,087,346,071 | 984,327,708 |
| Instrumented | 141.580 | 4,037.132 | 975,005,852 | 4,303,705,018 | 1,109,539,738 |
| Reference guarded | 140.627 | 271.315 | 1,588,045,476 | 922,597,431 | 2,510,235,053 |

Each requested Zig backing baseline includes the preparation, owners and arenas
retained at that arm's entry. Peak above baseline is the maximum additional
requested backing during its three cuts and assertions. The instrumentation
disables allocator resize/remap and excludes owner restart, later publication
probes, cleanup, artifact comparison, C/SQLite allocations, OS memory and RSS.
First continuation includes reconstruction, execution and publication; it is not
an isolated restore measurement. Different baselines and arena growth preclude
interpreting these values as isolated per-runtime memory costs.

Releasing completed imported-candidate inspection reduced the first-cut backing
baseline from about 3.37 GB at `afa36d7` to 350 MB. Process peak RSS increased
from 5,902,909,440 bytes in the `9d32bdc` sample to 11,388,616,704 bytes at
`c1e2ffb`. These results establish the narrower temporary allocation lifetime,
not an overall memory or latency improvement. The 354.26-second run rebuilt its
test binary, while the 217.75-second `9d32bdc` run reused it; elapsed times are
not a like-for-like comparison. No break-even count or model efficacy claim
follows.
