---
name: tool-construction
description: >-
  Construct and direct retained Horos computations when they help the task.
  Use general source records or admitted components, inspect actual results,
  and keep control of evidence, delegation, and changes of direction.
---

# Computational workspace

Use an ordinary tool, direct reasoning, or an existing program when it fits.
Construct a program when an algorithm can remove repeated mechanical work or
express a useful investigation. Construction is optional. A pending computation
never determines your next action: leave a question unanswered, inspect other
evidence, ask the user, park the work, or pursue another approach.

## Discover the actual interface

Use `program.describe` for `source_records`, `values`, `examples`, `bindings`,
or the frozen `components`. Responses are paged; follow their offsets to obtain
omitted portions. The source-record interface is the existing Horos language:
values, functions, recursion, schemas, effects, and handlers. It is not Zig text,
a host script, raw BPI3, or native callbacks. Use the returned schema and examples
instead of guessing indices or encodings.

Component recipes remain useful for the frozen Table domain. `instances` select
catalog components, `bindings` connect actual imports and exports, and `entry`
selects an exported function. Use unique instance keys and an acyclic linking
graph. The catalog below supplies the actual signatures. General algorithms need
not fit this catalog; use `source_records` when they do not.

## Construct and execute

The model action is `program` with a `command` sum. For example, a recipe build is
`{"command":{"tag":"build","value":{"source":{"tag":"json_text","value":"<recipe JSON>"},"source_kind":"component_recipe","exposures":[]}}}`.
The canonical action schema supplies every field. A source-record build uses
`source_kind: "source_records"` and may explicitly request interaction exposures.
Build checks and compiles code; it does not execute the algorithm.

A successful build returns a program reference and its actual schemas. Inspect
these before choosing inputs. For configured Table data, call `context.materialize`
with `input: {"tag":"authorized_input","value":"<configured id>"}` and an
empty `sources` list. Use its returned value reference with `work.start`. Other
materializations can select frozen snapshot ranges or labeled hypothetical data.
Every reference is checked for task ownership and current permission.

`work.start` selects a program, typed input, and run policy. The ordinary default
runs one bounded slice. Explicit `owner_scheduled` continuation with a `terminal`
stop permits mechanical execution across quanta without a model turn per quantum.
A real unbound input still parks the work. Use `work.inspect`, `work.collect`, and
`context.expand` to read outcomes and paged values. Equal payloads can have
different provenance; preserve their actual origins.

Programs are reusable code; work identifies one execution. A changed algorithm
is a new program and new work over explicit data. Never relabel a retained
continuation with another image. Parameterize inputs instead of embedding the
current expected answer or dataset into the program.

## Interaction and delegation

Exposures are requests to the construction owner, not proofs of continuation
capabilities. An actual port states its answer schema, generation, and available
controls. `work.interact` requires the current work revisions and port identity.
A single-use answer consumes that opportunity once. An admitted alternative port
uses genuine multi-shot application, retains its template, and exposes real branch
results. Internal branch control is available only at a driver port; the complete
work item can still be parked or cancelled between execution quanta.

No input port implicitly invokes a model. Supply a checked value yourself, use a
value produced by computation, or explicitly delegate a permitted snapshot read
or a selected model/profile/effort. A model answer remains a judgment. It cannot
turn a hypothesis into authenticated evidence or expand the task's authority.
Unknown delivery remains unknown; cancellation does not prove an external effect
was undone. Capture and reply interpretation are separate durable stages.

Use `work.wait` only when you choose to wait for selected observations. New user
input interrupts the wait through the ordinary inbox. `park` retains state;
`cancel` requests actual cleanup, which may itself suspend or fail. A final
controller answer parks unjoined work and does not erase unresolved obligations.

## Evidence and reconsideration

`context.select` chooses retained values for subsequent controller inference.
The selected view replaces preceding research exchanges while preserving user
instructions, current policy, skills, and actions. Its coverage is only the
selected values. Use `context.expand` on the view, values, or provenance to reach
omitted material. A filter over partial data cannot establish exhaustive absence.

Use diagnostics to repair a construction while preserving the intended behavior.
Compiler admission establishes structural laws, not task correctness. Check useful
independent inputs and discriminate empty, missing, duplicate, ambiguous, and
conflicting results where they matter. Do not retry an unchanged failed proposal
without new information, or invent hidden callbacks to bypass a denial.

Keep the program/reference and a precise account of what ran and what it showed.
Do not build a workflow, promotion system, or new skill for each computation.
Unloading these instructions does not erase retained programs or grant new powers;
subsequent operations still use the ordinary workspace and current permissions.
