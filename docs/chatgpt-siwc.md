# ChatGPT plan inference

Protean can use a ChatGPT plan through the separately installed native `siwc`
executable. API-key inference remains an explicit, independent billing choice.
Neither signing in nor selecting an account grants inference permission.

Install `siwc` with `brew install tkersey/tap/siwc`, or use its
[native release archives](https://github.com/tkersey/skills-zig/releases).
The adapter recognizes releases 0.1.1 through 0.1.5 and credential protocol 1.
The helper's macOS archive requires macOS 15 or later on ARM64; its Linux
archive targets x86-64 musl. Protean does not download or upgrade the helper.
API-key, offline, inspection, and retained-capture recovery do not need it.
Neither installed executable requires Node, Python, a compiler, or adjacent sources.

Register once, using a local account label:

```sh
siwc login --app protean --new-account personal
siwc status --app protean --account personal --json
siwc models --app protean --account personal --json
```

For an existing registration, use `siwc login --app protean --account personal`.
If plan usage is disabled, add `--enable-plan` to that existing-account login.
Login is interactive and has no `--json` flag. Protean never starts login itself.

Copy `examples/adaptive/adaptive.chatgpt.example.json`, set its snapshot and skill
paths, and confirm that its approved model is in the account's catalog. The
example requests `gpt-6-astra` with medium effort. An unavailable model requires
an explicit compatible configuration; Protean does not choose a substitute.

```sh
protean validate --config ./approved-chatgpt.json --chatgpt-account personal
protean run --config ./approved-chatgpt.json \
  --authorize-inference --chatgpt-account personal \
  --task "Explain the entry point using source evidence." --state-dir ./chatgpt-task
```

Validation checks local structure and route compatibility without invoking the
helper. It does not prove account availability, consent, or model eligibility.
Configured `serve --transport stdio` accepts the same selection. Operator billing
diagnostics go to stderr, preserving protocol stdout.

Use `--siwc-bin ABSOLUTE_PATH` to select an executable, or let Protean resolve
`siwc` from absolute entries in the trusted launch PATH. `--siwc-auth-dir
ABSOLUTE_PATH` selects the helper's store. Otherwise the store is
`$HOME/.config/siwc`; neither `XDG_CONFIG_HOME` nor `SIWC_AUTH_DIR` selects it.
Pass the same custom directory to the operator's `siwc` commands using
`--auth-dir ABSOLUTE_PATH`.

The default store and any declared custom store are protected from snapshot,
configuration, and skill ingestion. A declared directory need not exist.
Model input files must have exactly one hard link. Protean rejects multiply
linked files, including harmless ones, because an additional directory entry
could alias protected credentials. Copy such inputs to distinct regular files.
Protection checks filesystem identity without inspecting auth-store records.
`--siwc-auth-dir` also declares protection in API-key mode without selecting or
executing the helper. Embedding hosts supply `configuration.Options.home` and
the same `ProtectedRoots` capability for model-bound files. Host credential
selections and helper settings remain private process state; portable profiles
retain only the response route and an opaque registration binding.

Each new inference obtains a separate credential after checking the selected
model. The credential must match the frozen issuer, issued client registration,
and verified subject, with both invocation and direct-plan scopes. Recreating
the same label for another registration cannot replace a task's billing identity.
API-key files may rotate without changing that task's source kind.

The ChatGPT route sends HTTPS Responses requests with `store:false`,
`stream:true`, complete local history, and developer `additional_tools`
declarations. It requires null output-token limits, standard reasoning mode,
automatic reasoning context, and explicit effort. Explicit caching, cache
diagnostics, effort updates, and unsupported hosted tools are unavailable in
this integration. Request/response byte limits and inference deadlines retain
their independent meanings; null remains unbounded. A byte cap is not a token cap.

Protean retains raw terminal SSE captures before interpreting any tool proposals.
Capture-only restoration works without the helper, credentials, networking, or
a fresh inference grant:

```sh
protean resume --state-dir ./chatgpt-task --task-id TASK_ID
```

Do not add `--offline` to restore a live task. A later new acquisition requires
an explicit matching credential selection and ordinary inference authority.
Use the original compatible executable for historical tasks; this change does
not migrate state from another runtime or schema.

Pre-inference helper failures retain the physical attempt but settle it as
definitely not sent. A crash after durable dispatch or a lost post-dispatch
stream without a terminal observation remains uncertain. Protean never silently
refreshes and resends a Responses request. Captured authentication, usage-limit,
and transient plan failures can ask for repair through the existing question
interface. Reply with exactly `retry` using `respond` or `task.respond`; this
creates a new occurrence while retaining earlier messages, replay, and completed
tool results. `task.message` does not answer a suspended question. A rejected
delegated judgment leaves its target parked and requires a fresh checked delegation.

For plan limits, consult ChatGPT settings → Usage. Protean does not invent reset
times or remaining allowances. There is no automatic API-key billing fallback.

To stop active work, cancel it through Protean and then sign out explicitly:

```sh
siwc logout --app protean --account personal --json
```

After local sign-out, subsequent acquisitions fail while the registration remains
signed out. A bearer copied before logout can still arrive from an in-flight
helper or already be in use. Local logout cannot recall it. A nonzero logout
exit can mean local tokens were cleared but remote revocation was unconfirmed;
repeating logout cannot retry revocation after the refresh token was discarded.

A destination host must independently provide credentials matching the exact
issued registration, plus ordinary execution and disclosure grants. Signing in
again with the same email normally issues another client registration and does
not satisfy that binding. This integration does not copy stores or credentials
between hosts. `--no-browser` is a local loopback flow, not a device-code or remote
callback solution. The helper does not support proxy environment configuration.

Live acceptance additionally requires a consenting account and evidence for typed
calls, finalized reasoning replay, adaptive controls, delegated judgments,
renewal, and logout. Synthetic boundary tests do not establish those service results.
