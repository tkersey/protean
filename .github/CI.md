# CI feedback and qualification

`Zig 0.17 qualification` has a cheap source job followed by independent Linux
x86-64 authoring and native jobs. The `native` result gate requires all three
and enforces the existing complete-workflow maximum. Pull requests, main pushes,
and manual dispatches use the same complete inventory; there are no hidden
legacy-product or optional qualification lanes.

The workflow target is **300 seconds**, with a **360-second maximum**. Timing
includes setup, acquisition, compilation, downstream qualification, packaging,
and cache work before the terminal gate. The final workflow duration and cache
regime belong in the PR; a previous-head run is not current proof.

## Checks and reruns

The source job provisions `rg`, checks `repo_zig_paths.txt`. It does not require Zig or product
acquisition. It is source accounting, not a substitute for compiling a consumer.

The authoring job uses native setup with `--authoring-only`, then runs
`zig build check-protean -Dnative=false -Doptimize=safe`. This retains generic
construction tests, compile-time rejection cases, model/value contracts, helper
integrity tests, adaptive asset emission, formatting, and independent wire checks.
It does not acquire Kosmos or SQLite.

The native job authenticates Kosmos source and SQLite, builds the product, then
runs `check-native` and the public downstream installation witness concurrently.
The downstream reference is an immutable copy of that product; both checks must
finish successfully and the final product must match the copy. Native owners have their
own test root because Zig does not collect test declarations from named imported
modules. The integration root shares the actual application types/assets and
Kosmos module. Controlled peers exercise HTTPS, actual authored adaptive control,
tool construction/reuse, acquisitions, restart, cancellation and archive checks.
No paid provider calls are made.

`installations.mjs` accepts only an optional archive-seed directory and optional
reference executable. It creates a clean source package and consumer, then uses
OS execution boundaries to exclude Node/Python from acquisition, source emission,
public `addNativeSystem`, build/install, inspection, and offline execution. It
also verifies that altered Horos/Kosmos inputs reject through the public build
graph. Node is the external controller. The old `--scan-only`/`--output` modes and
`check-authoring-installation`, `check-native-host`, `check-native-consumer`, and
`native-example` targets are removed.

For an unchanged commit, rerun only the failed GitHub job when its diagnosed
cause has changed. A corrected commit requires a new run. Matrix fail-fast is
disabled so the other lane can still return useful evidence. A failed result is
never relabeled as passed because another check succeeded.

## Local feedback

Select checks for the changed behavior. Local verification shares one 300-second
wall-clock deadline, including setup, compilation and retries. Terminate the
command and descendants at that deadline; report incomplete verification, never
success. Documentation-only changes need diff/link review.

The supported product platforms remain macOS arm64 and Linux x86-64 musl. Local
macOS verification supplements the required Linux workflow; it does not replace
Linux qualification or add a new CI platform matrix.

```sh
# Cheap source accounting; rg is a development tool.
sh tools/check_zig_paths.sh

# Native bootstrap; append --authoring-only when only authoring is needed.
zig run tools/native/dependencies.zig -- setup \
  conformance/protean/dependencies.lock.json \
  conformance/protean/native-dependencies.lock.json \
  .protean-native/inputs "$(command -v zig)"

zig build check-protean -Dnative=false -Doptimize=safe
zig build check-native -Doptimize=safe
node test/protean/installations.mjs .protean-native/inputs zig-out/bin/protean
```

For a targeted HTTPS change, `check-native-https` selects the existing native
probe and independent endpoint. The native product path itself needs no Node,
Python, WASM kernel, or Kosmos JS delivery. Horos's independent oracle and
Kosmos's source-agreement/embedding qualification remain in their owning projects.

## Compilation and caching

The adaptive application emits its image, ordinary contracts and approved
catalog once. The public build helper shares the same writer and one host-side
Zig admission/metadata tool. Emitters use the build host; a target executable is
never run to produce metadata. SQLite and the native C bridge share one static
library per target ABI. Linux keeps the accepted self-hosted compiler backend;
C compilation and its existing optimization flags are unchanged.
The build driver shares the existing optimized standard-library hash primitive
through its private ABI. The standalone bootstrap remains standard-library-only;
source admission, both compiler/library identity passes and license checks remain.

Compiler caches use ordinary CI filesystem operations to save
useful compiler objects without deleting local outputs. They reject unsupported
or oversized snapshots. OS, architecture, compiler version, lane and locked
inputs remain part of the cache key. Setup-Zig's destructive automatic cache
post-hook stays disabled.

Local workspace checks compile each test root once and execute its existing
independent qualification groups concurrently in fresh processes. Every test in
the executable must belong to exactly one group. The standard Zig test runner
still checks each test's result, logged errors and allocator leaks; skipped or
interrupted tests leave qualification incomplete. Explicit group selection keeps
the same compile-filtered execution used by the Linux lanes.
Native runtime scenarios occupy at most two fresh fixture contexts, including
cleanup. Their independent qualification overlaps the adaptive/placement chain.

Transport archives are cached separately **per lane and dependency lock**.
Authoring can publish a Horos-only archive cache without occupying the native
job's cache key. Native setup verifies every restored archive/source/package;
a cache hit is not authentication. The downstream witness starts with fresh
sources and metadata, optionally seeding untrusted cached archives and reusing
compiler caches.
The fresh consumer directory contains its acquired sources, allowing Zig to
reuse matching compiler outputs across temporary paths on both native platforms.

Only the executed adaptive executable, manifest, program/contracts, runbooks,
and approved example resources are packaged as the native artifact. Retired
applications, optional stdio test clients, and duplicate observation reports are
not included. Artifact retention is CI evidence, not a new stable release.
