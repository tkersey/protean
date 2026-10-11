# Agent → Protean

Protean is the native adaptive application and reusable Zig library. Use
`protean`, `protean_native`, `protean_contracts`, `build_protean.zig`,
`src/protean.zig`, `check-protean`, and `examples/adaptive`. The corresponding
projects and modules are Horos (`horos`, `horos_data`) and Kronos (`kronos`).
Native overrides are `-Dhoros-source` and `-Dkronos-source`; new setup inputs
live in `.protean-native/inputs`. No legacy aliases or duplicate binaries exist.
`addNativeSystem`, `tool_build`, `tool_run`, `inference_set` and `skill_set`
keep their names, permissions and behavior.

The application identity `adaptive-agent` used by saved tasks and client requests;
`agent.*` / `adaptive-agent.*` semantic, schema and resource IDs;
`agent-host/1.0`, `agent-client-values/*`, `agent-native-*` serialized formats,
state namespaces and schema URNs; and `world.advance` stored operation labels
remain unchanged. Source-lock and build-manifest fields `boundary` / `world`
and publication-record field spellings remain schema, while their selected
repository URLs and contents now identify Horos and Kronos. Horos wire formats,
magic, numeric tags and hash domains are unchanged. Generic agents, ownership
boundaries, HTTP `User-Agent`, copyright and historical retirement references
retain their meanings and spelling. Tests still name removed paths when checking
that those former implementations remain absent.

Version 4.0.0-dev.0 and lineage ID `84371874` are retained. Zig computes the
name-derived fingerprint checksum `50216bba`; the downstream consumer likewise
retains lineage `93b78865` with checksum `6504cc54`. Package and inventory
identities are recomputed from actual renamed sources with Zig and the native
admission owner. No optional JS/WASM delivery is a native prerequisite.

No old state is discovered, moved or deleted; the prior local input directory
remains ignored by Git. Existing tasks keep their original program, runtime,
artifact and resource bindings. Renamed source can change build identities;
use the original pinned build when saved tasks are incompatible. No implicit
conversion, transcript reconstruction or cross-build restoration is promised.
