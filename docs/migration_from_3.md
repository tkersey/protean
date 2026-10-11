# Migration to the adaptive-first Protean product

The supported application is now the native `protean`. This contraction
follows the accepted tool-construction work and does not change Horos/Kronos
language or wire semantics. The last complete pre-consolidation Agent tree is
`9807f2a447969e43af4d25f11b5b3525bba6c28b`; prior implementations remain in Git
history and published artifacts.

Removed application entry points include the JavaScript runner/model stack,
parser and inquiry deployments, document/repository mutation environments,
`runtime/mobility/` server/browser/session routes, and the separately distributed
`repository-agent` and `native-minimal` executables. Their exclusive packages,
fixtures, CLI adapters, build roots and evidence campaigns are removed. There
are no compatibility runners or successful no-op redirects.

The corresponding exclusive authoring exports `agent.inquiry`, `agent.mobility`,
`agent.parser_intent`, `agent.parser_synthesis`, and `agent.parser_delivery` are
removed. Generic authoring, checked responders, adaptive controls, model/prompt/
skill contracts, compiled tools, inboxes and native-host APIs remain reusable.
The optional stdio verification client moved to `test/support/stdio-client.mts`.

Use the [native acquisition/build path](native-single-binary.md). The Node setup,
dependency, manifest, and package tools are replaced by the shared Zig bootstrap
and build graph. `-Dworld-runtime` is removed; native builds select authenticated
Kronos source and SQLite directly. The source lock is explicitly versioned as
`agent-native-source-lock/v2`, retaining exact approved native identities while
retiring the unused WASM delivery fields. Boundary 3.0.0 and World 6.0.0 release
tags, assets and descriptor bytes remain immutable.

Existing tasks and old deployments are not migrated, stopped, or deleted.
Continue operating old state with its original pinned executable and inputs.
The new artifact has its own runtime identity; equality of a model name,
application version, or source tree does not authorize resuming an incompatible
task. Distributed adaptive mobility is future work. Local checkpoint copying
continues to require exact compatibility and does not establish exclusive custody.
