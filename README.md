# Protean

Formerly Agent; see the [rename notes](docs/rename.md).

All tracked Zig code follows [TigerStyle](docs/tiger-style.md), enforced in CI
alongside the existing qualification checks.

Protean builds adaptive agents as typed, resumable programs. Its supported application is
**Protean**: a native executable that investigates a read-only snapshot,
selects among approved models and reasoning settings, loads approved skills,
asks questions, and optionally constructs, retains, inspects and moves computations.

The application is authored in Zig. Horos checks and compiles its control
flow into BPI3; Kosmos's portable semantic core and restricted native base own
execution and continuation. Protean supplies
provider I/O, tools, task storage, and CLI/stdio clients. The host does not
interpret a recipe or run a second application policy loop.

## Build and run

Use Zig **0.17.1**, `tar`, and `unzip`. Approved source archives and SQLite are
acquired and authenticated by a Zig bootstrap; Node and Python are not needed.
From this checkout:

```sh
zig run tools/native/dependencies.zig -- setup \
  conformance/protean/dependencies.lock.json \
  conformance/protean/native-dependencies.lock.json \
  .protean-native/inputs "$(command -v zig)"
zig build protean -Doptimize=safe
./zig-out/bin/protean describe-build
./zig-out/bin/protean demo --offline --state-dir ./adaptive-demo
```

Setup authenticates complete source inventories, seeds Zig's pinned Horos
package, and retains only native Kosmos source and SQLite inputs. Append
`--offline` to setup to require previously cached archives. Existing dependency
directories are rechecked and never silently replaced.

The offline demo uses recorded replies through the actual authored program.
For configured operation, see [Protean](examples/adaptive/README.md)
and the [native build and operations guide](docs/native-single-binary.md).
Inference requires explicit configuration, authorization, and a credential file;
there is no credential discovery or paid call in ordinary qualification.

Supported native targets are `aarch64-macos` and `x86_64-linux-musl`. SQLite,
the small native C bridge, libc, and OS facilities remain dependencies. The
installed agent needs no compiler, JS/WASM runtime, or adjacent source tree.

## Reusable authoring and embedding

Protean remains a library. `protean.system`, `Context`, and `compile` construct
ordinary Horos programs. Checked model responders retain request-time offers;
adaptive controls, inboxes, prompts, skills, compiled tools, interaction contracts,
and checked participant composition remain available to downstream authors.
Model calls, choices, and continuations belong to the program.
See the [authoring migration](docs/authoring-migration.md) for typed
Context construction, native shapes and explicit source-record boundaries.

The public `addNativeSystem` build function accepts caller-owned definition,
types, and environment paths, or an already emitted image/assets/types tuple.
It uses the same native source admission and asset/metadata writers as the
repository application. The [downstream recipe](test/consumers/adaptive/build.zig)
builds the adaptive application through that public API.

[Architecture](docs/architecture.md) ·
[Trust boundaries](docs/security_model.md) ·
[Adaptive model contracts](docs/model-invocation-v13.md) ·
[Native Responses](docs/native-responses.md) ·
[ChatGPT through siwc](docs/chatgpt-siwc.md) ·
[Computational workspace and placement](docs/computational-workspace.md)

## Qualification

```sh
zig build check
zig build qualify
```

Use `check` for local feedback on authoring and the native C compiler wrapper.
It runs source inventory, formatting, focused authoring and rejection tests, and
a real bundled-Clang build. The compiler witness changes a transitive header
and verifies the resulting object. It also checks that a failed compilation
preserves the previous usable object. For the full authoring suite use
`zig build check-protean -Doptimize=safe`.

Use `qualify` on the committed release candidate on each supported host.
It runs setup, TigerStyle, authoring, owner and workspace tests, recurrence,
packaged execution and placement, and builds and runs an independent downstream
consumer. The command reports elapsed time and identifies unfinished groups
if a check fails or the run is interrupted. Keep the usual Zig caches between
runs. Every selected execution still runs against the candidate.

Use `zig build qualify -- --list` to see the inventory. To investigate one
group with its prerequisites, run `zig build qualify -- --group NAME`.
Each local group has a 600-second limit. On a translated x86-64 Linux guest
on Apple silicon, export `ZIG_DEBUG_CMD=1` before invoking Zig.

Node is an external verification controller only. The independent native peer
uses controlled HTTPS, actual authored actions and created tools, killed/restarted
tasks, frozen inputs, malformed archives, and cancellation. The downstream witness
uses a clean source package and an OS executable boundary that excludes Node and
Python during acquisition, authoring, public-API building, installation, inspection,
and offline execution. Source and compiler caches are authenticated or reused
without deleting unrelated local data.

CI qualifies Linux and retains only the adaptive executable, its build metadata,
program/contracts, and example configuration. Each job and the complete workflow
must finish within 600 seconds. Compiled artifacts are reused only when their
complete input keys match; changed inputs rebuild, and every selected test runs.
Exact-head results belong to the PR; a previous run does not qualify a changed
candidate.

## Retired applications

The fixed repository agent, native minimal demo, inquiry/parser/document
applications, JavaScript runners, and JavaScript mobility deployment have been
removed. See [migration notes](docs/migration_from_3.md). Native placement uses
signed bilateral transfers with separate controller and work custody. Ordinary
checkpoint import preserves data and compatibility evidence; execution requires
the original owning namespace or an authenticated placement acceptance.

Horos's independent source oracle and Kosmos's source-agreement tests remain
outside this product. Kosmos's optional JS/WASM embedding remains supported by
Kosmos and is not a native Protean prerequisite.
