//! Private v10/v5 runtime codecs. Instantiate only with the frozen legacy
//! application's action declarations, never the current application's catalog.
const contracts = @import("protean_contracts");
pub fn Profile(comptime Base: type) type {
    return struct {
        pub const adaptive_identity = "agent.model.invoke.v10";
        pub const adaptive_context_identity = "agent.model.context.responses.adaptive.v5";
        pub const adaptive_context_version: u8 = 5;
        pub const reference_identity = Base.reference_identity;
        pub const context_identity = Base.context_identity;
        pub const Context = Base.Context;
        pub const adaptive_policy_identity = Base.adaptive_policy_identity;
        pub const AnswerType = Base.AnswerType;
        pub const Interpretation = Base.Interpretation;
        pub const BatchInterpretation = Base.BatchInterpretation;
        pub const InterpretationFailure = Base.InterpretationFailure;
        pub const representation = Base.representation;
        pub const declaration_count = Base.declaration_count;
        pub const ArgumentCodec = Base.ArgumentCodec;
        pub const DecodedAnswer = Base.DecodedAnswer;
        pub const ModelId = Base.ModelId;
        pub const Temperature = Base.Temperature;
        pub const MessageText = Base.MessageText;
        pub const ProtocolIdentity = Base.ProtocolIdentity;
        pub const ToolName = Base.ToolName;
        pub const ToolDescription = Base.ToolDescription;
        pub const ToolSchema = Base.ToolSchema;
        pub const ArgumentsJson = Base.ArgumentsJson;
        pub const ResultText = Base.ResultText;
        pub const CallId = Base.CallId;
        pub const ReasoningConfig = Base.ReasoningConfig;
        pub const ModelParameters = Base.ModelParameters;
        pub const Message = Base.Message;
        pub const Messages = Base.Messages;
        pub const ToolDeclaration = Base.ToolDeclaration;
        pub const Tools = Base.Tools;
        pub const Request = Base.Request;
        pub const FunctionCall = Base.FunctionCall;
        pub const OutputItem = Base.OutputItem;
        pub const OutputItems = Base.OutputItems;
        pub const Output = Base.Output;
        pub const Result = Base.Result;
        pub const ReplayBytes = Base.ReplayBytes;
        pub const ToolResult = Base.ToolResult;
        pub const ReplayRequest = Base.ReplayRequest;
        pub const ReplayResult = Base.ReplayResult;
        pub const ReferenceRequest = Base.ReferenceRequest;
        pub const ReferenceResult = Base.ReferenceResult;
        pub const AdaptiveRequest = Base.AdaptiveRequest;
        pub const AdaptivePrepared = Base.AdaptivePrepared;
        pub const AdaptivePolicy = Base.AdaptivePolicy;
        pub const AdaptiveSkill = Base.AdaptiveSkill;
        pub const AdaptiveCatalog = Base.AdaptiveCatalog;
        pub const ContextOrigin = Base.ContextOrigin;
        pub const ReasoningSkills = Base.ReasoningSkills;
        pub const AdaptiveResult = Base.AdaptiveResult;
        pub const allDeclarations = Base.allDeclarations;
        pub const templateValue = Base.templateValue;
        pub const normalizationLimits = Base.normalizationLimits;
        pub const AdaptiveContext = struct {
            schema: contracts.Text(128),
            policy: [32]u8,
            task: [16]u8,
            tenant: contracts.Text(128),
            audience: contracts.Text(128),
            selection: @FieldType(Base.AdaptiveRequest, "selection"),
            top_effort: @FieldType(@FieldType(Base.AdaptiveRequest, "selection"), "effective_effort"),
            plan: @FieldType(Base.AdaptiveRequest, "plan"),
            watermark: u64,
            source_capture: @FieldType(@FieldType(Base.AdaptiveRequest, "plan"), "catalog"),
            source_request: @FieldType(@FieldType(Base.AdaptiveRequest, "plan"), "catalog"),
            response_id: ?contracts.Utf8,
            items: contracts.Bytes(null),
            /// Origin is projection-owned, never inferred from provider text.
            /// It distinguishes injected skill material from identical evidence
            /// and records which responses could have observed an evicted skill.
            origins: contracts.Vector(ContextOrigin, null),
        };
    };
}
