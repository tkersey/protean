# Model-directed semantic construction

This local implementation extends exact semantic-source inspection, authorized
observations, isolated interpretations, and generated runtime construction through
the existing workspace owners. The public contract is
[Computational workspace](computational-workspace.md).

Qualification remains incomplete. Linux deployment uses Bubblewrap user and
mount namespaces and its reported application PID; tracing and a PID namespace
are no longer required. Focused static x86-64 checks pass in the available
Apple-container Rosetta environment, including signaling, launcher death,
controller-file isolation, and exit status. Full product checks and the workflow's
600-second aggregate gate remain outstanding. No publication, deployment, paid
inference, or claim of autonomous model improvement accompanies this implementation.

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

The implementation rebases onto accepted controller reconstruction
`2e40ce45d0f4b9b2ee81838386d5f1e0693ea228`. Package/host 7.0.0, application 8.0.0,
workspace contract 4, and native state format 18 retain historical executable
bindings; they do not migrate old state implicitly. Horos is 6.1.0 and Kosmos is 9.1.0. The
[dependency lock](../conformance/protean/dependencies.lock.json) records exact
local source commits and archive identities. Remote archive transport remains
unqualified.

## Coverage and measurement scope

Existing source, runtime, workspace, and placement roots contain the acceptance
discriminators. The shared witness covers disclosure and partial expansion,
observer gaps and replay, alternative interpretation, generated source/layout
changes, independent negative mutants, retained activation, finite guard
divergence, cancellation, and peer transfer. The second producer invocation uses
the first candidate's source and exercises the same generated program.

The five execution arms are generic, built-in specialized, generated validated,
instrumented, and reference guarded. They start at the same retained request and
measure three matching cuts. Construction and validation are separate from
continuation, publication, and inspection. Logical artifact/reference byte counts
are not deduplicated disk footprint. Requested memory remains unmeasured where
the output says so. No break-even or universal speedup follows from these finite
measurements.

The [evaluation runner](../tools/evaluation/README.md) supplies matched real-model
comparison conditions and retains unsuccessful work. Its semantic preflight
prepares nine cases without inference. Independent model discovery and efficacy
remain unmeasured.

## Footprint

The comparison bases are Horos `ae8ace5`, Kosmos `6c70d24`, and accepted Protean
`2e40ce4`. Bytes count added and deleted test-source lines, including newlines,
rather than only the net file-size difference.

| Repository | Changed test files | Added bytes | Deleted bytes |
|---|---:|---:|---:|
| Horos | 3 | 26,035 | 0 |
| Kosmos | 8 | 76,091 | 773 |
| Protean | 13 | 163,855 | 8,340 |
| Total | 24 | 265,981 | 9,113 |

No test modules, directories, executables, or CI lanes were added. Protean's
existing workspace execution count advances from 12 to 13. The largest extension
is `workspace_runtime.zig` at 138,623 added bytes; the low module count does not
make this a small fixture change. Its generated producer and candidate are reused
by the custody, five-arm, and mobility checks, avoiding a third producer run.
Historical independent byte fixtures remain unchanged.

The packaged semantic core is 234,530 bytes, SHA-256
`fedc7ddb03284b65bb28ab6fdb390b3e7b5db1129ff0eaa502da6237dc3f4af8`.
Generated candidates use `kosmos.semantic-artifact/3` and
`kosmos.source-relation/1`; the existing artifact family remains `/2`.

## Qualification results

Commands use exact Zig 0.17.0 and Safe optimization on Apple silicon. Cold means
fresh local and global compilation caches with authenticated dependency source
packages available; warm reuses those caches and still executes the checks.
Times measure the build/check commands, including compilation. They do not
measure the Linux workflow's setup, archive transport, or aggregate elapsed gate.
Every command has a 600-second watchdog.

| Tree and command | Cold seconds | Warm seconds | Result |
|---|---:|---:|---|
| Horos `816d2d8`, `check check-package` | 198.309 | 105.816 | 266/266 steps, 932/932 tests |
| Kosmos `acf8d71`, `check` | 527.043 | 340.761 | 69/69 steps, 329/329 tests |

Horos reports 60 compiler steps: 60 executed cold, 49 executed and 11 cached
warm. Its largest reported individual compiler RSS is 2 GB; this is not aggregate
concurrent memory. Kosmos's committed TigerStyle ratchet passes at `acf8d71`
with 35 changed files, 5,762 changed lines, zero diagnostics, and 24 auditor tests.
Kosmos reports 12 compiler steps, all executed cold and cached warm, with a largest
individual compiler RSS of 4 GB. Its full check includes 9,570 independent source
agreement observations, Chromium and Firefox worker transfer, and extracted
package operation. Protean's full-tree and product qualification remains outstanding.
