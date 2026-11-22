# CI feedback and qualification

The required workflow must complete in **one attempt within 600 seconds of its
trigger**. The budget includes runner queueing, setup, acquisition, compilation,
every selected test, TigerStyle, and the terminal gate. The terminal `native`
gate measures from the run's `created_at`, rejects `run_attempt != 1`, and
requires TigerStyle and all four qualification lanes to succeed, or, for a
self-hosted fallback run, the macOS qualification job.

Pull requests and main pushes run on GitHub-hosted Linux x86-64 runners with
exact Zig 0.17.1 and safe optimization.

## Required inventory

The [TigerStyle gate](../docs/tiger-style.md) runs alongside the qualification
lanes. It checks every tracked Zig file at the exact committed PR head, main
push head, or manual-run head, including unchanged code. It runs the pinned
auditor's tests and launcher integration probes.

Each lane runs `zig build qualify -- --group GROUPS`, the same command and
groups as local qualification, against a private checkout of the commit.

| Lane | Groups | Checks |
| --- | --- | --- |
| `authoring` | `authoring-https` | Source inventory, `check-protean` and `check-native-https`: authoring, model/value contracts, construction, compile-time rejection, helper integrity, adaptive asset emission, formatting, the bundled-Clang header and failure witness, wire checks and the independent HTTPS endpoint. |
| `native` | `native-smoke`, `native-placement` | Build the adaptive product with LLVM; verify its manifest and protocol/state rejection through the isolated native deployment; execute the same binary through authenticated transfer, reopen, refusal and duplicate-acceptance checks. |
| `direct` | `direct-smoke` | Build the product with direct Zig x86-64 code generation and Zig’s bundled Clang for SQLite and the POSIX shim, run the split SHA-256 vectors against the direct fallback, and run the same deployment smoke. |
| `downstream` | `downstream` | Independently acquire, authenticate, package, build, install and execute the public `addNativeSystem` consumer; reject altered Horos and Kosmos inputs. |

The `native` and `downstream` lanes each upload a small build-identity file. The
terminal gate requires the independently built downstream product's program,
application-assets, dependency, compiler, target and backend identities to match
the product. Full local qualification makes the same comparison within one run.

## Self-hosted fallback

When GitHub-hosted runners never start a run's jobs, the
[fallback workflow](workflows/fallback.yml) runs on the Mac's self-hosted macOS
runner. It acts only when no job of the hosted run received a runner or ran a
step, and the branch still points at the run's commit. It then dispatches the
same workflow with `mac_backup=true` and `hosted_run` set to that run. A hosted
job that started and failed keeps its result; the fallback does not replace it.
`workflow_run` uses the workflow from the default branch. A manual dispatch can
cover a hosted queue that never starts, with `hosted_run` naming that run. The
gate of a `mac_backup` run verifies that `hosted_run` is the same workflow and
commit and that none of its jobs started.

A `mac_backup` run replaces TigerStyle and the Linux lanes with one job that runs
the complete local macOS `zig build qualify` on the self-hosted runner: TigerStyle
and its launcher fixtures, authoring and the bundled-Clang witness, the LLVM
product with its smoke and placement checks, and the downstream consumer with
its identity comparison. The same terminal gate requires it to finish within 600
seconds. It does not exercise Linux x86-64 or the direct backend; the next
hosted run does. The runner keeps a persistent cache directory, advertised as
`PROTEAN_CI_CACHE`, for Zig's global and local caches. It executes the dispatched
commit directly on the Mac as its owner.

A Linux container under Rosetta could not fit the Linux lanes in 600 seconds:
its emulated compiler took 422 seconds to build the product alone.

## Coverage deliberately reduced

Required verification is the essential set above. The native task, adaptive and
projection owner suites, owner support and crash recovery, the workspace
execution, retention and history tests, source-oracle correspondence, and the
recurrence driver's capture/SIGKILL/reopen witnesses on both backends are no
longer required by CI or `zig build qualify`. They remain build steps for
diagnosis, for example `zig build check-native-owner`, `check-native-owner-support`,
`check-workspace-general`, `check-workspace-semantics` and `check-recurrence-driver`.
They do not gate a candidate, and their absence from a result is not a pass.

CI no longer retains the packaged adaptive application, so the historical
retention diagnostic is local: run `test/protean/workspace_runtime_retention.mjs`
with a baseline and a candidate executable. CI also no longer restores compiled
artifacts or compiler caches; every lane builds from source.

Earlier reductions remain in force. The required native smoke does not run the
extended controlled-provider, captured-record/archive, held-inbox or
signal-cancellation suite, or the complete offline authored demo; explicit
extended diagnostics still include them.

## Local feedback

Local verification uses a **600-second shared wall-clock deadline** on macOS
and Linux, including setup and compilation. `zig build qualify` terminates
commands and descendants at that deadline and reports unfinished groups as
incomplete.

The supported product platforms remain macOS arm64 and Linux x86-64 musl.
Native macOS verification supplements the required Linux workflow; emulation or
cross-compilation does not replace the native platform checks.

```sh
zig build qualify
zig build qualify -- --list
zig build qualify -- --group downstream
```

Transport archives remain untrusted until native acquisition authenticates
them. The downstream witness uses fresh sources and metadata even when matching
compiler work is available. No paid provider calls are made.
