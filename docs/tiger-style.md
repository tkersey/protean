# TigerStyle for Protean

This contract applies to all tracked Zig code, including tests,
examples and build tools. Its upstream reference is
[TigerBeetle TigerStyle at `ba8d4b3`](https://github.com/tigerbeetle/tigerbeetle/blob/ba8d4b347cbb29057fd52243d2909b7a830f9336/docs/TIGER_STYLE.md).
It adapts the
[skills-zig TigerStyle contract](https://github.com/tkersey/skills-zig/blob/ac19a3fabd0b32fae3f6bf1becf5368c724e96f3/docs/engineering/TIGER_STYLE.md)
to Protean's authoring library and native agent host. Safety, performance and
developer experience are the priorities, in that order.

## Design and ownership

Identify valid inputs, rejected states, the owner of each transition and its
failure behavior before choosing a representation. Require checked admission
to construct trusted states and preserve their invariants through public
operations. Keep authored control flow in Horos programs, execution and
continuation in Kosmos, and provider I/O, tools and task storage in Protean.

Preserve request-time model and tool offers, typed replies, task identity and
execution custody. Admit restored state before execution; imported checkpoint
bytes alone do not authorize resumption. Publish durable successors only after
validation succeeds and preserve the preceding authoritative state on failure.
Cancellation and retry must respect external effects and existing recovery
contracts. Style adoption does not change these behaviors.

Pass allocators, I/O and process capabilities explicitly. Returned owners must
outlive their source storage; borrows must remain within their storage lifetime.
Do not retain collection element pointers across growth or release. Group
acquisition with cleanup and preserve ownership on allocation failure and
partial construction. Check size arithmetic and conversions before use.

Use explicitly sized integers for persistent identities, wire fields and
serialized counts. `usize` remains appropriate for in-memory indexing and
allocator interfaces. Put units or qualifiers last, such as `output_bytes_max`.

## Work, allocation and errors

Give traversals an explicit progress argument over admitted inputs or an
existing caller-selected budget. Prefer checked worklists to native call-stack
recursion on input graphs. Recursive authored programs and recursive value
schemas remain supported; they do not require native implementation recursion.
Do not impose new global input, execution or allocation ceilings for style.

Dynamic allocation is permitted with explicit ownership, lifetime, growth and
failure behavior. Bound scratch and retained work by their admitted source or
existing capacity and resource contracts. Preserve caller-selected quanta,
supported execution and allocator failures.

Intentional event loops need the auditor's same-line `// tiger: event-loop`
directive and a review explanation of external control, cancellation and
per-iteration work. The marker does not establish a progress or resource bound.

Return malformed input, exhausted resources and environmental failures through
their declared error paths; do not discard errors with `catch {}` or
`catch unreachable`. Assertions express programmer invariants, not admission
checks that disappear when runtime safety is disabled. Use independent checks
at meaningful producer/consumer and persistence boundaries.

## Source shape and performance

Keep functions and test blocks within 70 physical lines and Zig lines within
100 columns. Multiline-string data is exempt from the column limit. Nested
functions are measured independently and excluded from the enclosing function's
line count. Explicitly `inline` type-driven expansion must terminate during
compilation and introduces no recursive native call frames.

Use precise names, narrow scopes and domain responsibilities when factoring
code. Preserve compile-time contracts and independent test observations.
Use spaces, remove trailing whitespace and resolve `TODO`, `FIXME` and `HACK`
markers before merging code.

Do not add explanatory source comments, docstrings or optional API comments.
Express intent through names, types and operations. Preserve unrelated existing
comments; mandatory legal notices and required machine directives remain
allowed. Put engineering rationale in the change description.

For a new data path, identify relevant CPU work, allocation, copying and retained
storage. Measure before adding caches; define their key, invalidation and owner.
Keep build inputs tracked so cached builds observe changed source.

## Mechanical gate

`tools/tiger-style.sh` acquires the immutable skills-zig auditor used by Horos
and runs its self-tests. It is a development dependency outside the runtime
package dependency graph. Git, Bash and exact Zig 0.17.0 are required.

From a clean committed checkout, run:

```sh
bash tools/tiger-style.sh --all HEAD
```

CI audits every tracked Zig file, including unchanged code, for pull requests,
main pushes and manual runs. TigerStyle
runs alongside runtime qualification and is required by the terminal `native`
gate within the existing 600-second total budget.

Whole-file checks reject
lines over 100 columns, tabs, trailing whitespace, unresolved marker comments,
discarded errors, unmarked `while (true)` loops, direct native recursion and
functions or test blocks over 70 lines. Zig's parser identifies function
boundaries and multiline direct calls; invalid syntax fails a full-file audit.
The optional `bash tools/tiger-style.sh <base-commit> HEAD` mode audits added
lines in existing files and fully audits new files, using the revisions' merge
base. It is useful for inspecting committed differences; CI requires the full
audit. The selected head must be checked out with a clean index and
tracked worktree. Binary-classified Zig changes and changed file types fail the
diff gate; the full audit rejects nonregular tracked Zig sources.

Acquisition failures, tool errors and auditor resource limits fail the check.
Mechanical checks cannot establish indirect recursion, lifetime safety, valid
error handling or semantic correctness. The skills-zig repository-mapping audit
is specific to skills-zig and is not a Protean check.

Run `bash tools/test-tiger-style.sh` after changing the launcher or pin. Its
temporary Git histories exercise valid and invalid changes, inherited debt,
full-source selection, revision checks, dirty indexes and worktrees, binary
diffs and nonregular sources. CI runs these probes without retaining fixtures.

## Verification

Keep [.github/CI.md](../.github/CI.md) authoritative for qualification, platform
coverage and time limits. TigerStyle supplements the existing checks.

Explain the affected invariant, owner, valid and invalid behavior, resource
growth, cleanup and compatibility impact when relevant. Reuse focused positive,
negative and boundary observations, including allocation failure where ownership
changes. Every required check must finish successfully against the delivered
state before the change is called verified.
