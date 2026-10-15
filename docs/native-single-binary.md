# Native Protean

`protean` is the supported application. Its human CLI and `agent-host/2.1`
stdio interface use one native task owner and one authored Horos program.
Kosmos evaluates the program and its saved continuation. Read-only snapshot work,
Responses I/O, and generated pure tools are native environmental capabilities.

## Native acquisition and construction

Use Zig 0.17.0. `tools/native/dependencies.zig` imports only the standard library,
so it can authenticate sources before any dependency code is executed:

```sh
zig run tools/native/dependencies.zig -- setup \
  conformance/protean/dependencies.lock.json \
  conformance/protean/native-dependencies.lock.json \
  .protean-native/inputs "$(command -v zig)"
zig build protean -Doptimize=safe \
  -Dhoros-source=.protean-native/inputs/horos \
  -Dkosmos-source=.protean-native/inputs/kosmos \
  -Dsqlite-source=.protean-native/inputs/sqlite
```

The stable source tuple is [Horos 5.0.0](https://github.com/tkersey/horos/releases/tag/v5.0.0),
[Kosmos 8.0.0](https://github.com/tkersey/kosmos/releases/tag/v8.0.0), and SQLite 3.53.4.
The [source lock](../conformance/protean/dependencies.lock.json) records the
exact immutable commits, authenticated GitHub archives, and complete
source/package inventories under `agent-native-source-lock/v2`. Kosmos owns
its separate optional JS/WASM release descriptor.

The release tags identify the exact source commits authenticated by this lock.
Setup downloads the pinned archives and authenticates their
transport bytes and source contents. Extracted source overrides supplied through
`-Dhoros-source` and `-Dkosmos-source` must match the complete locked inventory.

Setup performs bounded HTTPS acquisition, authenticates before invoking `tar`
or `unzip`, rejects links/special source entries, verifies complete source
inventories, checks SQLite's SHA-256/SHA3 identities and license, and seeds Zig's
normal package cache from verified Horos source. Append `--offline` to use
cached transport bytes only. A mismatched existing input rejects; choose a new
output directory rather than overwriting a previous pinned build's inputs.

The default native inputs are `.protean-native/inputs/kosmos` and
`.protean-native/inputs/sqlite`. Explicit `-Dkosmos-source`, `-Dsqlite-source`, and
`-Dhoros-source` overrides receive the same admission checks. Pure authoring
consumers can select `-Dnative=false`; they still authenticate Horos.

`addNativeSystem(b, dependency, options)` is exported by `build.zig`. A caller
supplies an executable name, an environment source, and either:

- `.application.source`: a definition exposing `System`, capabilities and
  resources, plus its input/output/failure/message type mapping;
- `.application.emitted`: an exact image, application metadata, and type mapping.

`tools/native/emit.zig` runs on the build host and emits the image and ordinary
contracts together. The shared metadata helper checks their correspondence and
records the selected target, optimization, compiler/library identity, source
locks, storage profile, SQLite flags, and license notices. Cross-compiled target
artifacts are never executed to produce build metadata. The public API and the
in-repository build share this implementation and the target's static C library.

See `test/consumers/adaptive/build.zig` for a complete downstream recipe:

```sh
protean_root="$PWD"
cd test/consumers/adaptive
zig build -Doptimize=safe \
  -Dkosmos-source="$protean_root/.protean-native/inputs/kosmos" \
  -Dsqlite-source="$protean_root/.protean-native/inputs/sqlite"
```

The product targets are macOS arm64 and Linux x86-64 musl. The Linux executable
is statically linked; macOS uses system libSystem. Native manifests contain no
build paths and do not claim to authenticate their enclosing binary. At runtime,
`describe-build` separately hashes the executing artifact. `licenses` exposes
the required Protean, Horos, Kosmos, Zig, SQLite, and applicable musl notices.

## Operate a task

```sh
./zig-out/bin/protean describe-build
./zig-out/bin/protean demo --offline --state-dir ./adaptive-demo
./zig-out/bin/protean validate --config ./approved-adaptive.json
./zig-out/bin/protean serve --transport stdio \
  --config ./approved-adaptive.json --state-dir ./adaptive-tasks
```

Configured inference additionally requires `--authorize-inference` and
`--credential-file FILE`. Credentials are not embedded in prompts, snapshots,
checkpoints or archives. No environment-variable discovery, proxy discovery,
redirect or automatic provider retry occurs. `--trust-root DER_FILE` selects
an explicit trust root; ordinary production uses OS trust roots.

Use `--help` for `run`, `status`, `result`, `respond`, `resume`, `cancel`, and
checkpoint commands. `status` and `result` read retained facts without loading
execution configuration. A task ID is required when selection is ambiguous.
Stable operation IDs and their original parameters support lost-ack retries;
a changed request cannot reuse the receipt. Questions bind identity, revision,
request digest, and answer schema. Follow-ups remain queued input, not answers.

The stdio API uses newline-delimited JSON-RPC 2.0. Discovery exposes the actual
application schemas, capabilities, limits, and current profile. Schema and
artifact reads are bounded. The small client in `test/support/stdio-client.mts`
is an external verification caller; it is not installed with the product.

A state directory admits one native owner. SQLite commits, sealed generation,
frozen resources, task revisions, occurrences, and acquisitions remain durable. A response acquired before restart is interpreted from its
original bytes rather than dispatched again. Unknown external delivery cannot
be automatically retried or declared cancelled. Cleanup failure and incomplete
shutdown remain distinct from application failure.

SQLite uses its system allocator and filesystem capacity; Protean imposes no
namespace byte quota or fixed SQLite heap. The linked library's actual BLOB
limit is queried at admission. A storage failure during capture publication
fences the owner; reopening retains unknown delivery and cannot reissue the
external call. No finite reserve promises publication of an unknown-size reply.

Opening a task service, importing, and exporting reconstruct the retained
dependency graph from canonical task, record, event, and operation bodies and
the compiled projection codecs. Saved requests bind to the program identity
decoded from their task's retained image; the launching image does not determine
that historical binding. Registered capability and schema checks still apply.
The audit checks stored dependency edges and
their lengths, and hashes each distinct reachable object once under one database
transaction. Large opaque checkpoints and captures are hashed in streaming form.
Raw captures remain valid retained data even when interpretation would reject
them. A missing edge or altered object fences the owner. This audit grants no
public artifact access and performs no environmental acquisition.
Import uses the same closure validator on its unpublished transaction. Rejecting
incompatible archive data rolls back without fencing the clean destination, so
valid work or a compatible import can follow in the same service. Actual Store
integrity, rollback, and publication failures retain their fencing behavior.

After this cold retention validation, native context preparation can reuse
checked ancestry within the Store's integrity epoch. The pure validator alone
creates an opaque validated context. Its cache binds the exact codec and
declaration order, catalog meaning, complete reference, task, tenant, audience,
profile and application. Each entry retains the dependency root and epoch.
Unrecognized roots must pass semantic validation and checks of every derived
root/history dependency edge before their facts become reusable. Only committed,
sealed storage can populate the cache; import verification uses full validation.
The Store projection boundary reconstructs missing cold retention validation
through the registered codecs before a sealed read view can reuse context facts.
Continuation in the importing service therefore warms normally without requiring
an export or process restart. Transaction-scoped import and audit projections
remain fully validating and cannot populate the context cache.
Reopen, replacement, integrity invalidation and fencing discard the cache.
Unrelated owner commits preserve it, as does ordinary descendant rejection.

Warm preparation reads the current visible history once and validates new
lineage up to an already checked ancestor. It does not reread all historical
captures and prepared requests. Every actual object read still checks its hash;
the cold audit remains required on reopen, import and export. This does not
promise discovery of an arbitrary disk bit flip in unread historical bytes
before every provider request. Validation facts confer no artifact access.

The committed 128-turn fixture reads 129 objects / 60,146 bytes on warm
preparation (one catalog plus each visible history chunk), versus 513 objects /
3,113,116 bytes through the generic v6 reader. Warm ancestry-validation bytes
are zero at 1, 8, 16, 32, 64 and 128 turns; the exact prepared provider-body
hashes agree in both paths. These are returned-object byte counts, not disk I/O
or a latency claim. Exact prepared requests remain fully journaled.

Native preparation and interpretation now borrow a scoped read view. The Store
establishes a SQLite snapshot before checking the integrity epoch, rejects owner
writes during projection, and releases the snapshot even when the adapter fails.
It checks integrity again before returning. Import verification borrows the
import transaction without committing or rolling it back. No projection snapshot
survives into provider I/O; the subsequent publication transaction independently
checks integrity under its writer lock. Generic readers use the same read-view
interface and continue to validate the complete context on every call.

The task owner rotates among eligible tasks, with one resident and one physical
worker. A held leaf does not prevent another task's pure steps, questions, inbox,
saved replies, or legal cancellation. A ready leaf waits for the worker without
preparing or charging another attempt. Callbacks bind the task, occurrence,
attempt, and owner epoch. Owned tasks use the supplied allocator; there is no
fixed task-count quota. Both native front ends use this scheduling owner.

Queue waits are measured in scheduling opportunities, not milliseconds. A pump
advances each examined task to the logical back and returns after one actual transition;
new admissions append behind existing continuations. With a fixed set of `N`
continuously eligible tasks and continued host pumping, a task has at most `N-1`
peer transitions ahead of its next turn. A drive executes at most 256 Kosmos
steps; storage, restoration and adapter work do not have a wall-clock deadline.
The deterministic native fixture checks both initial yielders reach execution
revision 1 in two pumps and a newcomer cannot overtake queued continuations.
With one acquisition held and six peers admitted, its 35-pump observation window
shows pure/inbox completion, cancellation, question presentation and repeated
yield progress; answering that question completes within the next eight pumps.
Those windows are verified upper bounds for that fixture, not measured latency
percentiles or a bound on arbitrary application completion.

The runnable list keeps a cursor instead of shifting every ID on each probe.
An idle scan visits the current list once without copying the list for every
waiting leaf. New admissions still enter at the logical tail; removal and parking
preserve that order. Membership updates remain linear, and each idle probe still
reads and validates its task and occurrence through the Store.

`zig build bench-native-scheduler -Doptimize=safe` measures this Service path with
the same authenticated native inputs as `check-native`. It holds an acquisition
slot and measures seven warmed idle scans at 256, 1,024, 4,096 and 16,384 ready
leaves. Setup, durable admissions and post-scan checks are outside the timer. The
fixture verifies unchanged durable state, no additional acquisition attempts and
retained worker identity. It is an opt-in measurement, without a timing threshold
in the correctness suite; it does not measure provider latency or the host loop.

On arm64 macOS 27.2 with Zig 0.17.0 Safe, alternating two process runs per
implementation gave these medians over 14 warmed scans per size:

| Ready leaves | Prior rotation (ms) | Cursor (ms) |
| ---: | ---: | ---: |
| 256 | 9.317 | 8.982 |
| 1,024 | 36.526 | 37.220 |
| 4,096 | 155.678 | 148.692 |
| 16,384 | 743.775 | 662.181 |

The 16,384-task samples ranged from 721.7–810.4 ms before and 641.4–706.7 ms
after. Smaller-case ranges overlapped, so this does not establish a speedup for
every size. The cursor removes about 4 GiB of ID shifting per 16,384-task idle
scan; Store reads and decoding remain. Admissions and removals still perform
linear membership work, and admission may shift IDs to preserve the logical tail.

Each drive publishes an outcome and owning checkpoint receipt together. The
Driver retains the receipt before storage publication, including if that commit
fails and fences the namespace. Switching tasks transfers the committed receipt
without serializing the state again. Receipts convey only local native custody;
durable copies remain ordinary data under the namespace owner.

`agent-host/2.1` retains bounded transport windows: framed RPC, output
backpressure, and artifact/event pages. These do
not accumulate into task-lifetime allowances. Parked tasks and archive records
have no application count cap. Status reports `pending_message_count` and a
bounded `pending_messages` view with `pending_messages_truncated`; `task.events`
provides the complete message history in pages. The inbox itself retains every
accepted message until its authored consumption or terminal disposition.

Orderly shutdown discloses every owned recovery task in order through bounded
`server.recovery` notifications followed by one `server.closed` notification.
Each carries `mode`, `disposition`, and a `recovery_tasks` page; concatenate the
pages, including the final one, for the complete list. A small or empty list needs
only `server.closed`. Pages contain at most the advertised `recovery_task_page`
IDs and advance only after entering the output queue. Frame limits, backpressure,
and the existing shutdown delivery deadline remain physical transport boundaries;
they do not limit retained task count or remove durable recovery records.

### Explicit recovery

Initialization requires an offer containing `agent-host/2.1`; clients offering
only older versions are rejected with the supported version. Discovery publishes
one method set and one immutable protocol schema, including `task.reconcile`,
recovery availability, and reconciliation events. The client JSON mapping is
`agent-client-values/1.1` for every application, including nested optionals.

For an unknown occurrence, 2.1 status includes `recovery` with its original
`occurrence_id`, `attempt_id`, and available `mechanisms`. Submit
`task.reconcile` with those IDs, `task_id`, `expected_revision`, a stable
`client_operation_id`, and `recovery: {"mechanism":"rederive"}`. Keep all
parameters unchanged when replaying that operation. The receipt identifies the
reconciliation and reports its current `pending`, `unresolved`, `capture_admitted`,
`reply_settled`, or `not_sent` status. Capture admission alone does not establish
a typed reply. Replay the unchanged operation to read its current status.

Pure recovery is compiled for frozen snapshot operations and admitted generated
tools. Admission validates the original bindings and seals a pending reconciliation
before scheduling computation on the existing worker. The callback receives owned
request, prepared-input, and profile bytes plus a cancellation signal; it has no
Store reader or environmental authority. The control loop and unrelated eligible
tasks continue while recovery runs. It does not invoke the original environmental
adapter. Original ambiguous-delivery history,
prepared inputs and captures remain private, including after archive import.
The provider currently has no receipt-retrieval adapter: its mechanism list is
empty and a rederivation request records an unresolved result without another
inference attempt.

An unsupported, unavailable, inconclusive, or rejected pure derivation records an
unresolved result and preserves the unknown attempt. Replaying its operation
returns that receipt after restart. Callbacks return these non-results explicitly;
errors remain operational failures and leave the pending reconciliation for
restart to mark interrupted. They do not certify a semantic non-result or permit
another invocation. Restart and import interrupt pending recovery without
automatically recomputing it. A new cancellation interrupts queued or running
recovery while preserving unknown delivery. Cancellation requested before a later
explicit reconciliation remains pending until recovery makes it legal to apply;
it does not prevent that reconciliation from computing a result.
If cancellation commits but interrupting queued recovery fails, the namespace is
fenced until reopen marks that recovery interrupted. Retrying cancellation then
returns its original receipt without dispatching recovery.

A capability with a compiled receipt adapter also advertises `lookup` when its
current grant permits retrieval. Selecting it seals a pending reconciliation and
receipt before dispatch through the existing worker. Replays cannot launch another
lookup, and a competing operation for that attempt conflicts while one is pending.
The pure verifier authenticates returned evidence against the original request,
prepared bytes, task, attempt, frozen profile, and ordered resources. Only verified
capture evidence or non-invocation proof can change the occurrence; inconclusive,
unavailable, or rejected evidence preserves unknown delivery. Non-invocation proof
permits cancellation, while another dispatch still requires explicit resume.
Receipt verifiers return semantic non-results explicitly as `RecoveryFinding`
values. Any verifier or input-read error remains an operational failure: it
does not commit a completed reconciliation, and restart records the pending
lookup as interrupted. Errors never certify rejected evidence.
Message and cancellation revisions do not invalidate the lookup's completion.
Restart or import marks a pending lookup interrupted without invoking a provider.
Evidence and predecessor reconciliation bodies stay private and are verified again
during archive admission and cold retention audit.

## Saved state and portability

Application 5 starts in a new namespace with state format 13, adaptive invocation
v11, context v7, and output v5. Existing tasks keep their original namespace,
image, and exact executable. They are continued by that executable; this feature
does not migrate or transplant their continuations. Do not delete old state as
part of an update.

The optional installer retains the current executable and its observed build
manifest under a content-addressed runtime directory before switching the
default executable:

```sh
node tools/native/install.mjs zig-out/bin/protean "$HOME/.local"
```

Qualification archives include the same helper as `install.mjs`; from an
extracted archive run `node install.mjs ./protean "$HOME/.local"`.

Its JSON output names `previous` and `current` executable paths. Keep the previous
path with the corresponding state-directory location, and use it for the old
task. The installer does not modify namespaces, move task data, or grant a new
binary authority over an old task. `bin/protean` selects the new executable;
`lib/protean/runtimes/SHA256/protean` remains independently runnable. New task
namespaces must use distinct paths. This helper requires Node only at install
time, not at runtime.

`test/protean/workspace_runtime_retention.mjs OLD_BINARY NEW_BINARY` exercises a
baseline task parked at a real question, installs the successor into a temporary
prefix, and answers/completes the old task through its retained original binary.

A saved task is bound to its exact image, runtime artifact, schemas, profile,
resources, and application identity. New binaries do not inherit resume authority
from an equal version string. Within the current format, restart and recovery
preserve those bindings and never automatically redispatch an ambiguous effect.

Checkpoint export/import verifies canonical schemas, object closure, occurrences,
captures, event facts, receipts, and compatibility before admission. A valid
archive is not permission to expose private captured data as a public artifact.
An interrupted import does not create a partly authoritative task.
Unknown delivery and uninterpreted captures can be archived, including captures
whose response framing fails interpretation. Import keeps these tasks parked,
preserves recovery receipts and the original private evidence, and does not
invoke an adapter. A captured response still needs its original interpretation
before reply settlement; an unknown attempt still needs explicit reconciliation.
Export refuses an occurrence with an active environmental dispatch.

Distributed adaptive mobility is not delivered. Copying an archive does not
transfer exclusive custody, credentials, or authority over ambiguous effects.

## Verification boundaries

`check-protean` checks reusable authoring, compile-time rejections, and independent
wire fixtures. `check-native` checks native owners plus the adaptive and HTTPS
peers. The peers run copied binaries under OS execution/file boundaries, using
controlled provider replies, real transport, kills/restarts, cancellation, tool
construction/reuse, and independently altered archives. No paid model calls run.
The complete aggregate remains `check-native`. CI distributes its existing checks
across the same three runners: authoring also runs `check-native-owner` and the
workspace program/semantics checks; native runs `check-native-packaged`; downstream
keeps its independent build. Source accounting starts independently; the terminal
gate requires it and all qualification lanes and retains the 360-second maximum.
The packaged adaptive peer runs its independent controller/recovery and workspace
groups concurrently, with separate state, snapshot, and HTTPS fixtures. Both
groups must finish, and their original assertions and command deadlines remain.

`check-native-recovery-crash`, included in `check-native`, kills the owner process
at 16 original-acquisition and receipt-lookup boundaries. Two fresh processes
reopen each surviving namespace and check occurrence state, interruption status,
exact capture retention, receipt replay, private evidence access, and token
accounting. Recovery never repeats an original invocation or starts a lookup
without a new explicit admission.

`node test/protean/installations.mjs` drives a clean public downstream build. Node
stays outside the product boundary; absolute Node/Python launches are denied
inside it. Setup, package acquisition, emission, `addNativeSystem`, install,
`describe-build`, and the offline demo execute there using native tools.
`check-workspace-semantics`, included in `check-native`, sends newly constructed
source through Horos's independent source oracle and native Kosmos. Passing
`-Dworkspace-wasm=/absolute/path/to/kosmos-kernel.wasm` additionally compares exact
native/WASM outcomes and alternates checkpoint producers. The oracle and embedding
are the authenticated dependency implementations, not production dependencies.
Use `check-workspace-runtime-retention -Dprevious-runtime=/absolute/path/to/protean`
to exercise an actual prior executable through a temporary installation.

The opt-in [model-use evaluation](../tools/evaluation/README.md) compares ordinary
actions, pure generated computation, and retained interaction on identical
evidence. Normal checks use controlled replies and make no paid inference calls.
