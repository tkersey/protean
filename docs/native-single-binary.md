# Native Protean

`protean` is the supported application. Its human CLI and `agent-host/2.0`
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
zig build protean -Doptimize=safe
```

The selected source tuple is Horos 4.0.0 at
`13713db071e6dba42ec06eabf224b628c2f3d3ed`, Kosmos 7.0.0 at
`5ca974c1a8d103e64d0facb80e8f1a01b82093c7`, and SQLite 3.53.4. The versioned
`agent-native-source-lock/v2` binds exact archives and complete source/package
inventories. It intentionally contains no WASM delivery contract. Kosmos owns
its optional JS/WASM release descriptor, which this build never rewrites.

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

`agent-host/2.0` retains bounded transport and scheduling windows: framed RPC,
concurrent owned tasks, output backpressure, and artifact/event pages. These do
not accumulate into task-lifetime allowances. Parked tasks and archive records
have no application count cap. Status reports `pending_message_count` and a
bounded `pending_messages` view with `pending_messages_truncated`; `task.events`
provides the complete message history in pages. The inbox itself retains every
accepted message until its authored consumption or terminal disposition.

## Saved state and portability

A saved task is bound to its exact image, runtime artifact, schemas, profile,
resources, and application identity. New binaries do not inherit resume authority
from an equal version string. Keep the original pinned executable to operate an
existing task. This consolidation introduces no automatic migration or hot upgrade.

Checkpoint export/import verifies canonical schemas, object closure, occurrences,
captures, event facts, receipts, and compatibility before admission. A valid
archive is not permission to expose private captured data as a public artifact.
An interrupted import does not create a partly authoritative task.

Distributed adaptive mobility is not delivered. Copying an archive does not
transfer exclusive custody, credentials, or authority over ambiguous effects.
Old deployment stores and published archives are untouched by source retirement.

## Verification boundaries

`check-protean` checks reusable authoring, compile-time rejections, and independent
wire fixtures. `check-native` checks native owners plus the adaptive and HTTPS
peers. The peers run copied binaries under OS execution/file boundaries, using
controlled provider replies, real transport, kills/restarts, cancellation, tool
construction/reuse, and independently altered archives. No paid model calls run.

`node test/protean/installations.mjs` drives a clean public downstream build. Node
stays outside the product boundary; absolute Node/Python launches are denied
inside it. Setup, package acquisition, emission, `addNativeSystem`, install,
`describe-build`, and the offline demo execute there using native tools.
Kosmos's independent source oracle agreement and optional JS/WASM embedding are
qualified in Kosmos's existing roots, not reimplemented in Protean.
