# CI feedback and qualification

The required pull-request workflow must complete in **one attempt within 600
seconds of its original automatic trigger**. The budget includes runner queueing,
setup, acquisition, compilation, every selected test, packaging, artifact and
cache transfers, TigerStyle, and the final identity comparison. The terminal `native` gate
measures from the run's `created_at`, rejects `run_attempt != 1`, and requires all
eleven qualification lanes and TigerStyle to succeed. A failed warmup followed by a successful
retry does not satisfy this requirement.

Pull requests and main pushes run the same inventory on native Linux x86-64 with
exact Zig 0.17.0 and safe optimization. Complete manual dispatches provide
supplemental evidence; they do not replace the original automatic PR run.
Selective `authoring`, `owners`, `downstream` and `retained-runtime` dispatches
are diagnostic and cannot pass the terminal qualification gate. The retained-runtime
diagnostic authenticates explicitly selected baseline/candidate product archives
and runs the existing old-task installation/continuation witness on native Linux;
it neither rebuilds those executables nor substitutes for full qualification. Matrix fail-fast remains disabled
so every selected lane can return evidence.

## Required inventory

The [TigerStyle gate](../docs/tiger-style.md) runs alongside the qualification
matrix. It checks every tracked Zig file at the exact committed PR head, main
push head, or manual-run head, including unchanged code. It runs the pinned
auditor's tests and launcher integration probes. The terminal
`native` gate requires both TigerStyle and the existing matrix, within the same
600-second original-trigger budget. The retained-runtime diagnostic omits
TigerStyle and still cannot pass the terminal gate.

| Lane | Checks |
| --- | --- |
| `authoring` | Source inventory, `check-protean` and `check-native-https`: authoring, model/value contracts, construction, compile-time rejection, helper integrity, adaptive asset emission, formatting, wire checks and the independent HTTPS endpoint. |
| `owners` | All 46 retained native task/response/model-custody owner tests, including their participant imports. |
| `owner-adaptive-control` | All nine retained adaptive owner tests. |
| `owner-support` | Native unit/context and process-crash recovery checks. |
| `workspace` | The 16 workspace execution and construction tests. |
| `workspace-retention` | The three retained-work, wait and delegated-answer tests. |
| `workspace-history` | The three history, cancellation-read and allocation-failure tests. |
| `correspondence` | Independent source-oracle agreement, capsule restoration and duplicate-custody rejection. |
| `native` | Build and package the adaptive product; verify its manifest and protocol/state rejection through the isolated native deployment. |
| `native-placement` | Execute the same current-run packaged binary through authenticated transfer, reopen, refusal and duplicate-acceptance checks. |
| `downstream` | Independently acquire, authenticate, package, build, install and execute the public `addNativeSystem` consumer; reject altered Horos and Kosmos inputs. |

The native lane publishes its completed product before deployment checks so
placement can proceed concurrently. The placement consumer authenticates the
current-run artifact and executes those exact bytes. The terminal gate compares
program, application-assets, dependency, compiler and target identities across
native, placement and downstream witnesses, and verifies that placement used
the packaged native binary. Downstream builds independently; it does not borrow
the native lane's executable. No paid provider calls are made.

`installations.mjs` creates a fresh source package and consumer. Its OS execution
boundary excludes Node/Python from acquisition, source emission, public build,
installation, inspection and offline execution. Node remains the external
controller. Both changed-input rejection checks remain required.

## Coverage deliberately reduced

The required workflow retires the packaged workspace-report and scripted runtime
scenarios, including controller adoption, outer/guest migration, specialization
reuse and runtime-view reframing. The native smoke no longer runs the extended
controlled-provider, captured-record/archive, held-inbox or signal-cancellation
suite. Independent HTTPS, native owner recovery and simple packaged placement
remain required, but do not establish all of those removed end-to-end observations.

The owner suite no longer imports the separate 48-case contract collection.
Two expensive adaptive capture/recovery tests, the adaptive reframing test and
the largest generated-evaluator custody test are deleted. The remaining 15
runtime-workspace tests and explicit scripted-runtime targets are optional diagnostics, outside the default native
aggregate and required CI. They are not deferred requirements or a substitute
qualification workflow. The removed reframing test uniquely exercised an
authored controller retaining its full action offers while abandoning a
boolean-demanding child, broadening evidence and executing novel GCD source
twice. Remaining direct construction and child-control checks do not reproduce
that complete controller observation. The invalid reconstructed-output test
retains foreign-value ownership, malformed-reference and acquired outer-handoff
cases. It retires separate uncited-claim, foreign-program and ordinary-origin
variants; the remaining origin case also exercises a pending acquired handoff.

The required native smoke also retires the complete offline authored demo: its
14 model calls, five work calls and eight ordered control receipts no longer form
a blocking packaged-execution witness. Explicit extended diagnostics still include
that scenario. Direct inference/skill control tests, isolated placement and the
independently installed consumer's execution/cancellation remain required; they
do not reproduce the complete demo.

Two further adaptive workspace tests are deleted: known-not-sent compiler restart
and successful redispatch, and captured compiler checkpoint import followed by
local resumption, exact source/image retention and execution of retained input.
The invalid-output recovery test retains all three selected rejection cases.
The surviving construction and custody tests do not replace those successful
end-to-end recovery sequences.

Workspace execution, retention and history still run once each across 22 tests.
CI compiles the three existing filtered groups separately; the full unfiltered
root is retained for local grouped execution. The 16 execution tests run in three
independent processes using the existing qualification runner, which rejects
omissions, overlaps, skips, failures and leaks. Local execution uses those same
partitions alongside retention and history. Selected list fixtures are reduced
from 300 to 32 entries and the deep recursive fixture from 50,000 to 2,048 steps. This retains the smaller-scale
semantic checks while retiring the former scale coverage. The retained-work
fixture uses 32 cooperative list entries, 32 scope works, 32 status-history
works and 32 provenance antecedents instead of 300, 256, 1,024 and 8,192.
It retains noncooperative work beyond the initial quantum, replay, cancellation,
profile replacement, paging and input-history checks, but no longer exercises
those large-history memory and repeated scheduling workloads. These changes alter
verification scope, not supported product inputs or production semantics.

## Local feedback

Local macOS verification uses a **600-second shared wall-clock deadline per
repository**, including setup, compilation and retries. Terminate commands and
descendants at that deadline and report unfinished verification as incomplete.
This local allowance is separate from the original-trigger CI budget.

The supported product platforms remain macOS arm64 and Linux x86-64 musl.
Native macOS verification supplements the required Linux workflow; emulation or
cross-compilation does not replace the native platform checks.

```sh
bash tools/tiger-style.sh --all HEAD
sh tools/check_zig_paths.sh
zig run tools/native/dependencies.zig -- setup \
  conformance/protean/dependencies.lock.json \
  conformance/protean/native-dependencies.lock.json \
  .protean-native/inputs "$(command -v zig)"

zig build check-protean check-native-https -Doptimize=safe
zig build check-native -Doptimize=safe
node test/protean/installations.mjs .protean-native/inputs zig-out/bin/protean
```

These are selectable entry points, not permission to run every command beyond
the shared deadline. The default native aggregate uses the retained smoke and
owner/workspace checks. Explicit diagnostic targets retain their own coverage
and do not automatically become required again.

## Compilation, caching and artifacts

The five authoring test roots, both native owner test roots, and all three general
workspace groups use Zig's native x86-64 backend on Linux, retaining safe
optimization and every selected test. macOS keeps its existing backend;
the production native executable keeps LLVM. This reduces repeated LLVM test
compilation but does not exercise those test bodies through LLVM on Linux.
Compile-time rejection and independent execution checks remain selected.

Exact compiled-artifact keys bind compiler identity, target, recipe and source
inputs. Restored manifests verify output bytes and executable modes. Every
selected test still executes after a cache hit. Compiler caches and transport
archives can reduce repeated work, but the workflow must also fit its original
attempt when current compiled artifacts are absent. A preceding failed run is
not a preparation phase.

Transport archives remain untrusted until native acquisition authenticates
them. Compiler snapshots are bounded and reject unsupported filesystem entries;
optional cache failures do not waive required build, test or artifact failures.
Setup-Zig's automatic compiler-cache post-hook stays disabled. The downstream
witness uses fresh sources and metadata even when matching compiler work is
available.

The executed product artifact contains the adaptive executable, manifest,
program/contracts, runbooks and approved example resources. Identity artifacts
bind the native, placement and independent downstream observations. Retention
provides CI evidence, not a stable release. Report the original-trigger elapsed
time, actual cache regime and any incomplete checks in the PR.
