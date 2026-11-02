# Canonical adaptive authoring in Protean

Protean uses Horos's canonical shape-preserving authoring interface. The
current adaptive application uses invocation v11, context v7, output v5, and
native state format 21. Disposable examples are recreated; retired adaptive v5
tasks and state-format 11 databases are not migrated. See
[saved state and portability](native-single-binary.md#saved-state-and-portability).
The core ABI 3, BPI3, and PST3 identities remain unchanged.

`Context.init(builder, registry)` creates one shared `context.author`.
`context.schema(T)` returns `Schema(Shape(T))`; `context.literal(T, value)` returns
a checked, context-owned `Value(Shape(T))` without requiring a Body. Literals can
be reused in sibling bodies within that Context. `context.external` returns an
operation retaining its payload and reply contracts. Model responder and adaptive
control definitions return typed function handles, and inbox declarations retain
their reply shape. `Profile.interpreter(context)` and `interpretAll(context)`
also return typed functions for ordinary named calls.

```zig
const c = context.author;
const entry = try c.function("entry", .{
    .input = try context.schema(Input),
}, try context.schema(Output), .{});
const body = try c.body(entry);
const input = try body.parameter("input");
const output = try body.product(try context.schema(Output), .{
    .result = try body.field(input, "value"),
});
try c.define(entry, try body.ret(output));
return c.module(entry, try context.schema(Failure));
```

Horos's shared native classifier owns portable shape normalization. Protean's
Text, Bytes, Utf8 and Vector names alias those canonical wrappers. Its value codec
and model JSON projection consume that classification while retaining their own
encoding, validation and JSON-specific restrictions. A missing bound is `null`;
zero and finite bounds retain their distinct meanings.

## Consumer dispositions

| Consumer | Current boundary |
|---|---|
| `src/authoring.zig`, `examples/adaptive/definition.zig` | Shared Context, native schemas, global checked literals, typed operations/functions and named constructions |
| `src/adaptive_controls.zig`, `src/text_inspection.zig` | Typed fields, updates, vector operations, branches and helper results; no recursive schema or numeric field-name reconstruction |
| `src/responders.zig`, `src/model_interpretation.zig` | Typed model operations, candidate-admission functions and calls; exact checked effect-site ID for registry certification |
| `src/model_invocation.zig` | Native contracts and typed interpretation factories; Profile.declare takes the shared Context and returns its typed operation; Profile.source.declare is reserved for component/malformed-source integration |
| `src/inbox.zig` | Typed operation declaration; ordinary calls use Body.perform; the unused public poll helper is removed and raw lifecycle fixtures emit their explicit perform term |
| Catalogs, tools, interaction, compiled-tool and participant records | Their public records contain source IDs; conversions occur at those record boundaries |
| `test/protean`, `test/authoring_tests.zig` | Valid typed constructions use named handles; source/admission/malformed-program tests retain their raw IR purpose |
| `test/consumers/adaptive` | Builds the actual migrated adaptive definition through the public native-system API |

Use `horos.authoring.interop.schemaId`, `valueId`, `operationId` or `functionId`
only where a source record requires an ID. Context-based `valueId` accepts global
literals; Body-based access checks lexical visibility. Raw value or term adoption
cannot assert a shape. The remaining component imports use Horos's checked
interop API with the actual complete computation contract.

The selected Horos/Kosmos revisions and authenticated source, archive, package
and API identities are in `conformance/protean/dependencies.lock.json` and the
Horos package binding in `build.zig.zon`. Qualification uses those exact bindings;
uncommitted local-module development checks do not qualify a dependency tuple.

## Typed recursive participants

Protean 8 retains the canonical `library.hyper` interface introduced with the
qualified Protean 7/Horos 7 tuple. The recursive
participant fixture promises its effectful task schema before constructing the
reciprocal pair, then completes the task with its actual peer captures. Its
retained `ana` emitter uses typed state, named fields and typed Need operations;
repeated requests and work after a counterpart returns remain ordinary authored
control flow. Forcing the delayed task obtains its callable value. Applying that
value executes the task's model and read effects.

Component symbols and registry certification still use explicit source interop.
`authoring.interop.importFunction` checks the installed function against its
actual callable contract before ordinary authoring can call it.
`authoring.interop.componentModule` permits the declared component imports while
retaining completion, capture and component-admission checks. The deliberately
false capture fixture continues to mutate IR and must fail ownership admission.

The dependency lock binds the complete development tuple, including the Kosmos
artifact built with the selected Horos package. Rollback restores the preceding
lock and package manifest together; saved tasks retain their original executable
and image bindings.

## Adaptive-only public surface

Protean 8.0.0 is a breaking source cleanup. The generic ReAct factory is removed without
a replacement factory, alias, or relocated package. The adaptive application
continues to author its own loop. No retained adaptive root used the deleted
conversation, decision, observation, scope, set, approval, deliberation,
clarification or equality helpers. Their dedicated tests did not establish an
additional supported product. Unknown private downstream clients have not been
inventoried.

The table records every export of the pre-pruning `src/protean.zig` root and the
affected implementation/test modules. Test names identify qualification owners;
they do not claim that all final-candidate checks have already passed.

| Symbol/path | Retained root or protected invariant | Disposition | Replacement/consumer migration | Qualifying test |
|---|---|---|---|---|
| `package_version` | Package identity | retain public | Existing package/version owner | build and downstream identity checks |
| `Context / src/authoring.zig` | Shared adaptive authoring owner | retain public | Existing typed Context | test/protean/catalogs.zig |
| `system` | Adaptive application and embedding | retain public | Existing system descriptor | test/consumers/adaptive |
| `compile` | Checked adaptive program publication | retain public | Existing compiler entry | test/protean/composed_owners.zig |
| `compileObserved` | Observed checked publication | retain public | Existing compiler observations | test/protean/recursive_participant.zig |
| `CompileStage` | Publication observation contract | retain public | Existing compileObserved contract | adaptive asset emission |
| `CompileOptions` | Publication options | retain public | Existing compile options | adaptive asset emission |
| `contracts / src/contracts.zig` | Adaptive wire and native contracts | retain public | Existing data-only owner | test/protean/values.zig |
| `admission / src/admission.zig` | Protected sites, private calls, resources and speculation | retain public | Preserve actual-source checks | test/protean/admission.zig |
| `catalogs / src/catalogs.zig` | Model, skill, interaction and tool catalogs | retain public | Existing checked installation | test/protean/catalogs.zig |
| `callable / src/callable.zig` | Nominal callable origins | retain public | Existing checked source integration | test/protean/callable.zig |
| `participant / src/participant.zig` | Checked adaptive participant composition | retain public | Existing typed participant/component path | test/protean/recursive_participant.zig |
| `responders / src/responders.zig` | Model request-time offers and protected-site evidence | retain public | defineModel/defineModelObserved and Body.call | test/protean/model_custody.zig; adaptive emission |
| `interaction / src/interaction.zig` | Adaptive question and interaction extension contracts | retain public | Existing interaction records | test/protean/dialogue_probe.zig |
| `inbox / src/inbox.zig` | Adaptive pending questions and inbox | retain public | Existing inbox operations | adaptive owner/native tests |
| `tools / src/tools.zig` | Checked tool declarations and pure compiled tools | retain public | Existing descriptors and compiled-tool owner | test/protean/compiled_tool.zig |
| `model_invocation / src/model_invocation.zig` | Typed model request/reply and interpretation | retain public | Existing Profile owner | src/model_invocation_tests.zig |
| `adaptive_controls / src/adaptive_controls.zig` | Model/effort and skill lifecycle selection | retain public | Existing typed control functions | adaptive owner tests |
| `model / src/model.zig` | Approved model declarations | retain public | Existing model descriptor | test/protean/catalogs.zig |
| `prompt / src/prompt.zig` | Adaptive prompt construction | retain public | Existing prompt constructors | compile-time prompt rejection tests |
| `skill / src/skill.zig` | Approved skill declarations | retain public | Existing skill descriptor | test/protean/catalogs.zig |
| `react / src/react.zig` | No retained adaptive dependency | delete | No replacement; direct application composition where needed | Retained admission witnesses below; source inventory |
| `conversation / src/conversation.zig` | No retained adaptive dependency | delete | No replacement; direct application composition where needed | Retained admission witnesses below; source inventory |
| `decision / src/decision.zig` | No retained adaptive dependency | delete | No replacement; direct application composition where needed | Retained admission witnesses below; source inventory |
| `observation / src/observation.zig` | No retained adaptive dependency | delete | No replacement; direct application composition where needed | Retained admission witnesses below; source inventory |
| `scopes / src/scopes.zig` | No retained adaptive dependency | delete | No replacement; direct application composition where needed | Retained admission witnesses below; source inventory |
| `sets / src/sets.zig` | No retained adaptive dependency | delete | No replacement; direct application composition where needed | Retained admission witnesses below; source inventory |
| `approval / src/approval.zig` | No retained adaptive dependency | delete | No replacement; direct application composition where needed | Retained admission witnesses below; source inventory |
| `deliberation / src/deliberation.zig` | No retained adaptive dependency | delete | No replacement; direct application composition where needed | Retained admission witnesses below; source inventory |
| `clarification / src/clarification.zig` | No retained adaptive dependency | delete | No replacement; direct application composition where needed | Retained admission witnesses below; source inventory |
| `value_equality / src/value_equality.zig` | No retained adaptive dependency | delete | No replacement; direct application composition where needed | Retained admission witnesses below; source inventory |
| `src/authoring_imports.zig` | No remaining caller after pruning and typed model-call migration | delete | Existing Horos interop at actual source boundaries | source inventory and authoring checks |
| `responders.invokeModel / responders.invokeModelObserved` | Raw convenience duplicates typed responder calls | delete | model_custody pairModule uses defineModel and Body.call | test/protean/model_custody.zig |
| `tools.Observation` | Unused label union with no adaptive consumer | delete | Existing adaptive evidence contracts remain authoritative | source inventory |
| `tools.CommitResult` | Only obsolete approval fixture used this union | delete | No replacement approval workflow | source inventory |
| `src/model_interpretation.zig` | Candidate admission behind Profile | retain internal | Existing typed interpreter owner | src/model_invocation_tests.zig |
| `src/test_root.zig / test/authoring_tests.zig / test/protean/authoring_tests.zig` | Retained verification roots | retain internal | Remove obsolete imports; keep composed_owners and recursive_participant | check-protean |
| `test/protean/approval_probe.zig` | Protected-source negatives and tool metadata | delete | Resource negatives in admission.zig; metadata/no-commit case in compiled_tool.zig | protected resources admit one consumption and reject raw minting or duplication; tool metadata and dispatch share one declaration without granting commit |
| `test/protean/observation.zig` | Resource minting and protected handler rejection | delete | Direct retained admission witnesses | test/protean/admission.zig |
| `test/protean/approval_equality.zig` | Deleted equality helper execution across scalar and recursive values | delete | No retained equality workflow; general source semantics stay with Horos/Kosmos | source inventory |
| `test/protean/selection.zig` | Obsolete deliberation construction and allocation tests | delete | No replacement product | source inventory |
| `test/protean/decision_scopes.zig` | Obsolete decision/scope helper contracts | delete | No replacement product | source inventory |
| `test/protean/clarification.zig` | Obsolete clarification workflow | delete | No replacement product | source inventory |
| `test/protean/model_custody.zig` | Distinct offers and continuation after two model calls | retain internal | Named typed fields, products and calls | two scoped model calls retain separate offered sets and post answer continuation |
| `test/protean/admission.zig` | Direct protected-boundary witnesses | retain internal | Add valid single-use, forged-mint and double-consumption cases | protected resources admit one consumption and reject raw minting or duplication |
| `test/protean/compiled_tool.zig` | Tool declaration integrity | retain internal | Move metadata/no-commit witness from approval fixture | tool metadata and dispatch share one declaration without granting commit |
| `test/protean/dialogue_probe.zig` and raw cleanup fixtures | Deliberate source construction and ownership/admission negatives | retain internal | `horos.source.library.generator` and `horos.source.library.cleanup` | native owner/workspace tests |
| `test/consumers/adaptive/package_surface.zig` | Exported-package adaptive API and removal contract | retain internal | Compile against the extracted package during downstream installation | installations.mjs |

The retired approval tests also exercised placement, revalidation, authority,
amendment and scoped policy behavior. Observation tests exercised live/simulated
interpretation and live-proof workflows. Those unsupported workflow observations
are retired, not claimed to be reproduced by the direct witnesses. Protected raw
commit, stolen private call/lambda, resource escape, protected handlers, unsafe
speculation and multi-shot origin checks remain in `test/protean/admission.zig`.
Horos continues to reject unauthorized resource minting and repeated consumption;
the direct witness first admits the corresponding valid one-consumption program.

The native task/runtime owners, adaptive resources, `addNativeSystem`, and
`test/consumers/adaptive` remain in the build graph. Source inventory entries and
test imports are pruned together. No protocol family or saved-task identity check
changes as a consequence of these source removals.

## Consolidation qualification

`Profile.declare(context)` and the protected responder share the existing source
declaration cache. The returned typed operation retains its request/reply shapes;
its source identity remains the identity used for certification and effect rows.
`Profile.source.declare(builder)` remains only for source/component integration
and deliberate unclassified/misclassified admission fixtures. A typed operation
does not grant permission to perform a protected model request without its
responder. `Inbox.Profile.poll` is removed; ordinary code uses `Body.perform`
with the declared operation.

Pruning qualification on native macOS arm64, Zig 0.17.0 safe, passed
`zig build check-protean -Dnative=false -Doptimize=safe --summary all`:
33 steps and 130 tests before model declaration migration, then 33 steps and
131 tests after migration. The latter includes a shared-operation identity and
protected-bypass test. A preceding attempt had three failing pointer-equality
assertions: checked external-operation import returns fresh wrappers for the
same source identity. Corrected assertions compare actual operation IDs.

The pruning and declaration candidates emit the same 162,202-byte adaptive BPI3
image, SHA-256
`742e751d20c91057ffe7bf2da3960d86d3bc86dfde50a660f3d9bbc01d03a3d2`.
The qualified prerequisite's `native-identity.json` artifact from
[run 40513895462](https://github.com/tkersey/protean/actions/runs/40513895462),
head `1e8a9fd9324c3cd492aabd1c08f46eeaf8148d6c`, records the same program
digest on native Linux x86-64 musl with the selected Horos/Kosmos prerequisite
pins. This establishes image identity for those intermediate pruning/declaration
candidates against that baseline. It does not establish arbitrary checkpoint
compatibility or final qualification against the new Horos 8/Kosmos tuple.

The package version is now 8.0.0. Maintained raw generator/cleanup fixtures use
Horos's `source.library` boundary; ordinary generator clients stay typed.
The downstream build compiles removal/retention expectations against the actual
exported Protean module, and installation inspects retired paths in that package.
These new checks executed in the Linux qualification below. The coordinated PR
records their current native macOS qualification separately.

The retained model-custody fixture previously had no active build-root import.
It now runs through the existing native owner root, including the typed paired
model-call witness, request-time offers, later-offer rejection and protected
model-site negatives. Its presence in the source inventory alone was not
execution evidence. All 46 native owner cases passed on Linux in the run below.

The exact selected Horos and Kosmos commits, archive transports, normalized source
inventories, Horos package profiles and API-file digests are recorded in the
[dependency lock](../conformance/protean/dependencies.lock.json). The Kosmos
evaluator bundle remains 275,293 bytes and differs from the prerequisite only
in its embedded Horos package identifier. Artifact authentication does not replace
execution qualification.

The current candidate revision, dependency tuple, artifact identities, complete
requirement mapping and command outcomes are maintained in
[Protean #61](https://github.com/tkersey/protean/pull/61), coordinated with
[Horos #179](https://github.com/tkersey/horos/pull/179) and
[Kosmos #76](https://github.com/tkersey/kosmos/pull/76). Those records distinguish
current qualification from the immutable observations below.

Native Linux qualification at Protean
`99d583a0654266a668238b1192322c8cb3534eab` passed all eleven lanes and the
terminal identity/budget gate in
[run 40578373860](https://github.com/tkersey/protean/actions/runs/40578373860):
525 seconds from the original trigger, first attempt. That run selected Horos
`013d783dd45a7994f1c888f66f98a7003c173a79` and Kosmos
`00b568ac29178ba71d01a95db7c90a739ec6fecc`. Native, placement and independently
built downstream identities agreed. Package absence expectations, changed-input
rejection and the retained recursive restoration witness executed. Linux used
Zig 0.17.0's native backend.

The callable admission root includes the previously unwired positive comparison:
shared schemas conservatively reject ambiguous callable origins, while distinct
nominal callable origins admit the safe speculative callback. Model-custody and
protected-site tests execute through the retained owner roots.

The authenticated Linux product from that run also passed
[historical installation/continuation](https://github.com/tkersey/protean/actions/runs/40579548030/job/122454925233)
and [full adaptive controls](https://github.com/tkersey/protean/actions/runs/40579544770/job/122454912139).
The controls witness executes the complete fourteen-call offline prefix, eight
ordered control receipts, tool-authorization cases and protocol/signal
cancellation. Its deployment receipt records 37 traced executions in private
user/mount/PID namespaces without a live provider.

Historical retention is a separate `retained-runtime` diagnostic using
authenticated product archives and `workspace_runtime_retention.mjs`. It retains
the original executable, frozen question/profile, captured source and task
namespace while installing the successor into a separate namespace. The existing
controlled loopback HTTPS provider asks first, then reads source evidence and
reports after the original question is reopened and answered. The witness checks
provider call identities and count even after the original snapshot file changes.
Both 60-second waits and the ten-minute lane limit remain unchanged. The full
controls witness separately qualifies the complete offline prefix; the similarly
named workspace lane alone does not establish either observation.

Compared with prerequisite run 40513895462, that product's executable is unchanged
in size at 17,701,016 bytes, while its digest changes with its build identity. The
162,202-byte program and 873,620-byte application asset are byte-identical to the
prerequisite. Compressed transport is 6,390,723 versus 6,390,739 bytes. Horos #179
records representative clean/incremental compilation, authoring allocations,
graph counts and image sizes; Kosmos #76 records interpreter-work and checkpoint
allocation comparisons. These observations do not establish whole-product speed
improvements or arbitrary checkpoint compatibility.

Each successor candidate requires its own applicable qualification. The Linux
observations above apply only to their recorded candidate, bindings and
authenticated executable. The coordinated PR records current supported-platform
qualification and serial review outcomes.
