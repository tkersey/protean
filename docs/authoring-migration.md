# Horos 4 authoring in Protean 4 development

Protean uses Horos's canonical shape-preserving authoring interface. Its native
host and wire contracts remain unchanged: model invocation v7–v10, ABI 3, the
current native host/build interfaces, and state format 11 keep their owners.

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
| `src/model_invocation.zig` | Native contracts and typed interpretation factories; raw effect/declaration helpers retain their source-admission purpose |
| `src/inbox.zig` | Typed operation declaration; `poll` remains an explicit raw source-term integration |
| `src/value_equality.zig` | Public comparison retains its input shapes; the recursive runtime-schema visitor uses Dynamic and checked refinement |
| `src/decision.zig`, `src/scopes.zig`, `src/react.zig`, `src/observation.zig` | Existing runtime source-schema interfaces retain IDs; their authoring helpers use explicit Dynamic children and checked mapping of actual callable contracts |
| `src/clarification.zig`, `src/approval.zig`, `src/deliberation.zig` | Raw source owners retain continuation, protected-site and multi-shot construction; typed equality and handler helpers use the canonical interface |
| `src/authoring_imports.zig` | Private checked import of source literals and computation contracts; callers supply names and actual contracts must agree |
| Catalogs, tools, interaction, compiled-tool and participant records | Their public records contain source IDs; conversions occur at those record boundaries |
| `test/protean`, `test/authoring_tests.zig` | Valid typed constructions use named handles; source/admission/malformed-program tests retain their raw IR purpose |
| `test/consumers/adaptive` | Builds the actual migrated adaptive definition through the public native-system API |

Use `horos.authoring.interop.schemaId`, `valueId`, `operationId` or `functionId`
only where a source record requires an ID. Context-based `valueId` accepts global
literals; Body-based access checks lexical visibility. Raw value or term adoption
cannot assert a shape. The private source adapters validate literal bytes or map
an actual complete computation contract through Horos's checked interop API.

The selected Horos/Kosmos revisions and authenticated source, archive, package
and API identities are in `conformance/protean/dependencies.lock.json` and the
Horos package binding in `build.zig.zon`. Qualification uses those exact bindings;
uncommitted local-module development checks do not qualify a dependency tuple.
