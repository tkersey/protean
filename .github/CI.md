# CI feedback and qualification

The required workflow must complete in **one attempt within 600 seconds of its
trigger**. The budget includes runner queueing, setup, acquisition, compilation,
every selected test, TigerStyle, and the terminal gate. The terminal `native`
gate measures from the run's `created_at`, rejects `run_attempt != 1`, and
requires TigerStyle and all four qualification lanes to succeed.

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

Lanes do not exchange artifacts. Full local qualification additionally requires
the downstream consumer's program, application-assets, dependency, compiler and
target identities to match the product it builds.

## Self-hosted fallback

When GitHub-hosted runners never start a run's jobs, the
[fallback workflow](workflows/fallback.yml) runs on the Mac's self-hosted Linux
runner. It confirms that failed jobs never received a runner and that the branch
still points at the run's commit, then dispatches the same workflow with
`mac_backup=true`. Every job of that run uses the `mac-backup` runners, under the
same 600-second gate. A failed check on a hosted runner does not trigger the
fallback. `workflow_run` uses the workflow from the default branch. A manual
dispatch with `mac_backup=true` also covers a hosted queue that never starts.

The Mac runners are ephemeral x86-64 Linux containers under Rosetta, one job
each, started by per-slot launch agents. Run enough slots for TigerStyle and the
four lanes to proceed in parallel. Each slot mounts its own persistent cache
directory and advertises it as `PROTEAN_CI_CACHE`; qualification then keeps
Zig's global and local caches there instead of in the ephemeral workspace.
Slots never share a cache, so no lock crosses a VM boundary.

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
