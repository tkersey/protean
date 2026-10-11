# Protean verification

The current product is the native adaptive application plus reusable Protean
construction and host APIs. Horos owns compilation/linking; Kronos owns
execution and continuation. The adaptive application and supplied tool-construction
skill are retained from the accepted tool-construction implementation.

Current qualification belongs to the exact consolidation PR head. Historical
provider trials and previous-head CI results do not qualify this candidate.
Routine verification uses recorded or controlled provider replies, never paid
calls or discovered credentials.

| Existing surface | Required observation |
| --- | --- |
| `adaptive_controls.zig` | Authored model/effort selection, skill transitions, stale revision rejection, idempotence, deactivation and eviction. |
| `model_custody.zig` | The checked responder retains the original offered set across suspension. |
| `adaptive_responses.zig` and its declarative corpus | Envelope, replay, usage, exact integers, Unicode, pairing, capabilities, compatible history and opaque-context exclusion. |
| `adaptive_recovery.zig` | Acquired-response restart, original captures, frozen resources, bounded state and allocations. |
| `native_tasks.zig` and `runtime/native` tests | Durable ownership, receipts, questions, inboxes, reservations, archive admission, resource limits, protocol and shutdown behavior. |
| `native_adaptive.mjs` and `adaptive_native_peer.mjs` | Copied native executable; controlled HTTPS; actual authored decisions; skill/model changes; held I/O; crash/restart; questions; cancellation; generated-tool build, run, reuse and foreign-reference rejection. |
| `native_archive.mjs` | Independently decoded captures and deliberate closure, profile, private-artifact, receipt and event corruption. |
| `native_https.mjs` | TLS chain/hostname/expiry, bounded bodies, truncation, deadlines and absence of redirects/retries. |
| `installations.mjs` | Clean source package and public `addNativeSystem` acquisition/build/install/inspection with Node/Python excluded by the OS execution boundary. |
| `values.test.mjs` | Independent canonical wire observations for the archive/capture peer's small codec. |

The fixed demo's general manifest and archive-rejection checks now use the
adaptive peer. Product-specific parser, inquiry, repository mutation, document,
and JavaScript mobility tests are retired with their applications. The old JS
model normalizer is removed: its established intersection wire bytes are fixed
expectations in `native-responses-v1.json`; native-only cases retain their own
explicit expected outcomes. No second provider implementation runs as an oracle.

The 14-call adaptive trajectory and generated-tool scenarios use the actual
compiled application. They establish neither live-model quality nor cache reuse,
billed cost, exhaustive scheduling, or all maximal input combinations. Transient
prefixes and marker placement are checked directly; hypothetical eager/naive
layout reports are retired.

The complete CI workflow retains its 300-second target and 360-second maximum,
including downstream qualification. No new platform matrix is required. Native
C/SQLite/libc are admitted dependencies; remaining JavaScript is an external
verification controller or wire support. A small shell source check reports
missing tracked inputs early. Kronos retains
its own optional JS/WASM embedding and independent source-agreement checks.
