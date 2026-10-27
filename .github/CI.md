# CI feedback and qualification

The required pull-request workflow must complete in **one attempt within 600
seconds of its original automatic trigger**. The budget includes runner queueing,
setup, acquisition, compilation, every selected test, packaging, artifact and
cache transfers, and the final identity comparison. The terminal `native` gate
measures from the run's `created_at`, rejects `run_attempt != 1`, and requires all
nine qualification lanes to succeed. A failed warmup followed by a successful
retry does not satisfy this requirement.

Pull requests and main pushes run the same inventory on native Linux x86-64 with
exact Zig 0.17.0 and safe optimization. Complete manual dispatches provide
supplemental evidence; they do not replace the original automatic PR run.
Selective `owners` and `downstream` dispatches are diagnostic and cannot pass
the terminal qualification gate. Matrix fail-fast remains disabled so every
selected lane can return evidence.

## Required inventory

| Lane | Checks |
| --- | --- |
| `authoring` | Source inventory, `check-protean` and `check-native-https`: authoring, model/value contracts, construction, compile-time rejection, helper integrity, adaptive asset emission, formatting, wire checks and the independent HTTPS endpoint. |
| `owners` | All 35 retained native task/response owner tests, including their participant imports. |
| `owner-adaptive-control` | All 12 retained adaptive owner tests. |
| `owner-support` | Native unit/context and process-crash recovery checks. |
| `workspace` | All 21 workspace-program tests from one compiled executable, run in three independent execution, retention and history groups. |
| `correspondence` | Independent source-oracle agreement, capsule restoration and duplicate-custody rejection. |
| `native` | Build and package the adaptive product; verify its manifest, protocol/state rejection and offline authored-control demo through the isolated native deployment. |
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
suite. Independent HTTPS, native owner recovery, the offline authored demo and
simple packaged placement remain required, but do not establish all of those
removed end-to-end observations.

The owner suite no longer imports the separate 48-case contract collection.
Two expensive adaptive capture/recovery tests and the largest generated-evaluator
custody test are deleted. The remaining 15 runtime-workspace tests and explicit
scripted-runtime targets are optional diagnostics, outside the default native
aggregate and required CI. They are not deferred requirements or a substitute
qualification workflow.

Workspace execution, retention and history still run once each within the same
21-test root, using the existing concurrent group runner. The large list fixture is reduced from 300 to 32 entries and the
deep recursive fixture from 50,000 to 2,048 steps. This retains the smaller-scale
semantic checks while retiring the former scale coverage. These changes alter
verification scope, not supported product inputs or production semantics.

## Local feedback

Local verification retains its separate **300-second shared wall-clock
deadline**, including setup, compilation and retries. Terminate commands and
descendants at that deadline and report unfinished verification as incomplete.
The CI scope reduction does not reset or increase an existing local allowance.

The supported product platforms remain macOS arm64 and Linux x86-64 musl.
Native macOS verification supplements the required Linux workflow; emulation or
cross-compilation does not replace the native platform checks.

```sh
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
