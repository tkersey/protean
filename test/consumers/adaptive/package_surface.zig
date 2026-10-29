const protean = @import("protean");

comptime {
    for (.{
        "react",    "conversation", "decision",      "observation",    "scopes",            "sets",
        "approval", "deliberation", "clarification", "value_equality", "authoring_imports",
    }) |name| {
        if (@hasDecl(protean, name)) @compileError("retired Protean export: " ++ name);
    }
    for (.{
        "Context",
        "system",
        "compile",
        "participant",
        "responders",
        "adaptive_controls",
    }) |name| {
        if (!@hasDecl(protean, name)) @compileError("missing adaptive Protean export: " ++ name);
    }
}

test "exported package retains only supported adaptive entry points" {}
