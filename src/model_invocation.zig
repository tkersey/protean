//! Protean 4 semantic model effects. Values are constructed by authored BPI3;
//! the environment only marshals the declared provider protocol and normalizes.
const std = @import("std");
const contracts = @import("protean_contracts");
const codecs = @import("model_codec.zig");
const models = @import("model.zig");

pub const semantic_identity = "agent.model.invoke.v3";
pub const replay_semantic_identity = "agent.model.invoke.v4";
pub const reference_semantic_identity = "agent.model.invoke.v5";
pub const context_semantic_identity = "agent.model.context.responses.v1";
pub const adaptive_semantic_identity = "agent.model.invoke.v6";
pub const adaptive_context_semantic_identity = "agent.model.context.responses.adaptive.v4";
pub const adaptive_policy_semantic_identity = "agent.model.policy.adaptive.v1";
pub const maximum_adaptive_request_bytes = 256 * 1024;
pub fn isModelIdentity(identity: []const u8) bool {
    return std.mem.eql(u8, identity, semantic_identity) or
        std.mem.eql(u8, identity, replay_semantic_identity) or
        std.mem.eql(u8, identity, reference_semantic_identity) or
        std.mem.eql(u8, identity, adaptive_semantic_identity);
}

/// Selection is subordinate to the immutable task policy. Neither the selected
/// profile nor a context reference can replace that policy's resource grant.
pub const AdaptiveSelection = struct {
    profile_id: contracts.Text(64),
    profile_digest: [32]u8,
    effective_effort: models.ReasoningEffort,
    control_revision: u64,
};
pub const AdaptiveInferenceProfile = struct {
    id: contracts.Text(64),
    model: contracts.Text(128),
    reasoning_mode: enum { standard, pro },
    reasoning_context: enum { auto, current_turn, all_turns },
    efforts: contracts.Vector(models.ReasoningEffort, 7),
    /// An explicit capability, never inferred from a model-name prefix.
    effort_update: bool,
    explicit_cache: bool,
    additional_tools: bool,
    cache_diagnostics: bool,
    opaque_family: contracts.Text(64),
    max_output_tokens: u32,
    request_bytes: u32,
    response_bytes: u32,
    timeout_ms: u32,
};
pub const EpochReason = enum { initial, model_change, effort_change, eviction };
pub const SkillResidency = enum { resident, transient };
pub const SkillMaterialization = struct {
    resource: ArtifactReference,
    skill_id: contracts.Text(64),
    version: contracts.Text(64),
    residency: SkillResidency,
    active: bool,
    introduced_at: u64,
};
pub const AdaptiveContextReference = struct {
    object: ArtifactReference,
    schema: contracts.Text(128),
    policy: [32]u8,
    selection: [32]u8,
    task: [16]u8,
    tenant: contracts.Text(128),
    audience: contracts.Text(128),
    epoch: u64,
    watermark: u64,
    eviction_generation: u64,
};
/// Large immutable history stays outside Kronos values. Adapters validate each
/// continuation against its original capture/resource closure before dispatch.
pub const AdaptivePlan = struct {
    epoch: u64,
    reason: EpochReason,
    watermark: u64,
    eviction_generation: u64,
    prior: ?AdaptiveContextReference,
    catalog: ArtifactReference,
    skills: contracts.Vector(SkillMaterialization, 32),
};
pub const AdaptiveUsage = struct {
    input_tokens: ?u64,
    output_tokens: ?u64,
    cached_input_tokens: ?u64,
    cache_write_tokens: ?u64,
    reasoning_tokens: ?u64,
};
/// Captured HTTP response, before provider interpretation. The environment
/// retains these bytes separately from its bounded model result projection.
pub const CapturedResponse = contracts.CapturedResponse;
/// Immutable environmental data, not an authorization token. The environment
/// checks every binding and the full closure before rendering another request.
/// Sequence bounds describe the half-open range of ordered replay items.
pub const ContextReference = struct {
    digest: [32]u8,
    bytes: u64,
    schema: contracts.Text(128),
    profile: [32]u8,
    task: [16]u8,
    tenant: contracts.Text(128),
    audience: contracts.Text(128),
    first: u64,
    next: u64,
};
pub const maximum_replay_bytes: u32 = 2 * 1024 * 1024;
pub const ArtifactReference = struct { digest: [32]u8, bytes: u64 };
/// Context bindings are inside the hashed artifact too. A caller cannot relabel
/// another task's bytes merely by changing the fields of an external reference.
pub const ContextArtifact = struct {
    schema: contracts.Text(128),
    profile: [32]u8,
    task: [16]u8,
    tenant: contracts.Text(128),
    audience: contracts.Text(128),
    first: u64,
    next: u64,
    source_capture: ArtifactReference,
    parent: ?ArtifactReference,
    items: contracts.Bytes(maximum_replay_bytes),
};
pub const ReplayStatus = enum { complete, unsupported, capacity };
pub const Usage = struct { input_tokens: u64, output_tokens: u64, cached_input_tokens: ?u64 };
pub const protocol_identity = "agent.model.protocol.openai-responses-v2";
pub const MessageRole = enum { system, developer, user, assistant };
pub const TruncationPolicy = enum { disabled };
pub const TransportFailure = enum { unavailable, denied, interrupted, response_too_large };
pub const ProviderFailureKind = enum { http_status, response_failed, response_incomplete };
pub const UnsupportedResponse = enum {
    unsupported_protocol,
    unsupported_parameter,
    malformed_json,
    invalid_utf8,
    unsupported_status,
    unsupported_output_item,
    mixed_refusal,
    normalization_limit,
};

/// Every capacity is an application's declared value representation policy.
/// These capacities are neither turn budgets nor limits on program lifetime.
pub const Limits = struct {
    model_id_bytes: u32,
    temperature_bytes: u32,
    maximum_messages: u32,
    message_bytes: u32,
    maximum_output_items: u32,
    call_id_bytes: u32,
    arguments_json_bytes: u32,
    result_text_bytes: u32,
    provider_response_bytes: u32,
    /// Aggregate v6 reply budget, including normalized items and replay binding.
    /// Raw provider capture remains available when this projection is too large.
    maximum_adaptive_reply_bytes: u32 = 64 * 1024,
};

pub const Selection = struct {
    minimum_calls: u32,
    maximum_calls: u32,
    parallel_calls: bool,
};
pub const ResponsePolicy = struct {
    store: bool,
    stream: bool,
    background: bool,
    truncation: TruncationPolicy,
};
pub const NormalizationLimits = struct {
    maximum_output_items: u32,
    maximum_call_id_bytes: u32,
    maximum_name_bytes: u32,
    maximum_arguments_bytes: u32,
    maximum_argument_name_bytes: u32,
    maximum_argument_fields: u32,
    maximum_result_text_bytes: u32,
};

fn checkDeclarations(comptime Answer: type, comptime declarations: anytype) void {
    const info = @typeInfo(Answer).@"union";
    if (declarations.len != info.field_names.len)
        @compileError("Protean model requires one declaration per Answer variant");
    inline for (declarations, 0..) |declaration, index| {
        inline for (@typeInfo(@TypeOf(declaration)).@"struct".field_names) |field_name| {
            if (!std.mem.eql(u8, field_name, "name") and
                !std.mem.eql(u8, field_name, "description"))
                @compileError("Protean model declaration has unknown field '" ++ field_name ++ "'");
        }
        const name: []const u8 = declaration.name;
        if (name.len == 0 or name.len > 64)
            @compileError("Protean model declaration name must contain 1 through 64 bytes");
        for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-')
            @compileError("Protean model declaration name must match [A-Za-z0-9_-]{1,64}");
        if (!std.unicode.utf8ValidateSlice(declaration.description))
            @compileError("Protean model declaration description must be UTF-8");
        inline for (declarations, 0..) |earlier, earlier_index| {
            if (earlier_index < index and std.mem.eql(u8, earlier.name, name))
                @compileError("Protean model declaration name is duplicated");
        }
    }
}

/// The union defines answer association; declarations supply its provider names.
/// An answer may propose an operation or answer an ordinary question. Neither
/// kind authorizes dispatch; the enclosing protected composition owns admission.
pub fn Profile(
    comptime Answer: type,
    comptime declarations: anytype,
    comptime limits: Limits,
) type {
    // Only descriptor derivation runs at comptime; application control does not.
    @setEvalBranchQuota(100_000);
    const CodecProfile = codecs.Profile(Answer);
    comptime checkDeclarations(Answer, declarations);
    comptime for (@typeInfo(Limits).@"struct".field_names) |name| {
        if (@field(limits, name) == 0)
            @compileError("Protean model limit must be positive: " ++ name);
    };
    if (limits.maximum_adaptive_reply_bytes < 128)
        @compileError("adaptive reply budget must hold a capacity result and exact usage");
    const maxima = comptime blk: {
        var name: usize = 1;
        var description: usize = 0;
        var schema: usize = 2;
        for (declarations, @typeInfo(Answer).@"union".field_types) |declaration, Variant| {
            name = @max(name, declaration.name.len);
            description = @max(description, declaration.description.len);
            schema = @max(schema, codecs.json.ToolSchema(Variant).value.len);
            if (limits.arguments_json_bytes <
                codecs.json.maximumToolArgumentsByteLength(Variant))
                @compileError("Protean model arguments_json_bytes cannot represent every admitted answer");
        }
        break :blk .{ .name = name, .description = description, .schema = schema };
    };
    return struct {
        const Self = @This();
        pub const reference_identity = reference_semantic_identity;
        pub const context_identity = context_semantic_identity;
        pub const Context = ContextArtifact;
        pub const adaptive_identity = adaptive_semantic_identity;
        pub const adaptive_context_identity = adaptive_context_semantic_identity;
        pub const adaptive_policy_identity = adaptive_policy_semantic_identity;
        pub const AnswerType = Answer;
        pub const Interpretation = @import("model_interpretation.zig").Result(Answer);
        pub const BatchInterpretation = @import("model_interpretation.zig").Result([]const Answer);
        pub const InterpretationFailure = @import("model_interpretation.zig").Failure;
        pub const representation = limits;
        pub const declaration_count = declarations.len;
        pub const ArgumentCodec = CodecProfile.Codec;
        pub const DecodedAnswer = CodecProfile.Decoded;
        pub const ModelId = contracts.Text(limits.model_id_bytes);
        pub const Temperature = contracts.Text(limits.temperature_bytes);
        pub const MessageText = contracts.Text(limits.message_bytes);
        pub const ProtocolIdentity = contracts.Text(protocol_identity.len);
        pub const ToolName = contracts.Text(maxima.name);
        pub const ToolDescription = contracts.Text(maxima.description);
        pub const ToolSchema = contracts.Bytes(maxima.schema);
        pub const ArgumentsJson = contracts.Bytes(limits.arguments_json_bytes);
        pub const ResultText = contracts.Text(limits.result_text_bytes);
        pub const CallId = contracts.Text(limits.call_id_bytes);
        pub const ReasoningConfig = struct {
            effort: ?models.ReasoningEffort,
            summary: ?models.ReasoningSummary,
        };
        pub const ModelParameters = struct {
            max_output_tokens: ?u32,
            temperature: ?Temperature,
            reasoning: ?ReasoningConfig,
        };
        pub const Message = struct { role: MessageRole, content: MessageText };
        pub const Messages = contracts.Vector(Message, limits.maximum_messages);
        pub const ToolDeclaration = struct {
            action_ordinal: u32,
            action_tag: u32,
            name: ToolName,
            description: ToolDescription,
            input_schema_json: ToolSchema,
            strict: bool,
            argument_codec: ArgumentCodec,
        };
        pub const Tools = contracts.Vector(ToolDeclaration, declarations.len);
        /// Ordered product fields are the v3 application contract.
        pub const Request = struct {
            protocol: ProtocolIdentity,
            model: ModelId,
            parameters: ModelParameters,
            messages: Messages,
            tools: Tools,
            selection: Selection,
            response_policy: ResponsePolicy,
            normalization_limits: NormalizationLimits,
            maximum_provider_response_bytes: u32,
        };
        pub const FunctionCall = struct {
            call_id: CallId,
            name: ToolName,
            arguments_json: ArgumentsJson,
            tool_ordinal_claim: u32,
            decoded_action: DecodedAnswer,
        };
        pub const OutputItem = union(enum) {
            function_call: FunctionCall,
            message: struct { role: MessageRole, content: ResultText },
            reasoning: struct { summary: ResultText },
        };
        pub const OutputItems = contracts.Vector(OutputItem, limits.maximum_output_items);
        pub const Output = struct {
            items: OutputItems,
            normalized_output_digest: [32]u8,
        };
        /// Sum ordinals are fixed in this order. Nested enums retain explicit u32 tags.
        pub const Result = union(enum) {
            output: Output,
            refusal: ResultText,
            transport_failure: TransportFailure,
            provider_failure: struct { kind: ProviderFailureKind, http_status: u16 },
            unsupported_response: UnsupportedResponse,
        };

        // Additive stateless contract. The v3 request/result wire remains exact.
        // Opaque provider items are bounded ordinary data, never host closures.
        pub const ReplayBytes = contracts.Bytes(maximum_replay_bytes);
        pub const ToolResult = struct { call_id: CallId, output: ResultText };
        pub const ReplayRequest = struct {
            invocation: Request,
            replay: ReplayBytes,
            results: contracts.Vector(ToolResult, limits.maximum_output_items),
        };
        pub const ReplayResult = struct {
            result: Result,
            replay: ReplayBytes,
            replay_status: ReplayStatus,
            usage: ?Usage,
        };

        // v5 leaves existing inline v4 consumers unchanged. Large captures and
        // replay stay in the task owner's immutable store instead of PST3.
        pub const ReferenceRequest = struct {
            invocation: Request,
            replay: ?ContextReference,
            results: contracts.Vector(ToolResult, limits.maximum_output_items),
            profile: [32]u8,
        };
        pub const ReferenceResult = struct {
            result: Result,
            replay: ?ContextReference,
            replay_status: ReplayStatus,
            usage: ?Usage,
        };

        /// v6 independently represents definition residency and call authority.
        /// The checked responder replaces invocation.tools from materialized,
        /// and replaces offered from its separately captured argument. All
        /// definitions still come from this compiled answer catalog.
        pub const AdaptiveRequest = struct {
            invocation: Request,
            policy: [32]u8,
            selection: AdaptiveSelection,
            plan: AdaptivePlan,
            materialized: [declarations.len]bool,
            offered: [declarations.len]bool,
            results: contracts.Vector(ToolResult, limits.maximum_output_items),
        };
        pub const AdaptivePrepared = struct { version: u32, request: AdaptiveRequest, body: contracts.Bytes(maximum_adaptive_request_bytes) };
        pub const AdaptivePolicy = struct {
            schema: contracts.Text(128),
            endpoint: contracts.Text(2048),
            audience: contracts.Text(128),
            profiles: contracts.Vector(AdaptiveInferenceProfile, 8),
            catalog: ArtifactReference,
            core_tools: [declarations.len]bool,
            permitted_tools: [declarations.len]bool,
            model_attempts: u16,
            control_transitions: u16,
        };
        pub const AdaptiveSkill = struct {
            id: contracts.Text(64),
            version: contracts.Text(64),
            description: contracts.Text(256),
            instructions: ArtifactReference,
            tools: [declarations.len]bool,
        };
        pub const AdaptiveCatalog = struct {
            skills: contracts.Vector(AdaptiveSkill, 32),
        };
        /// Audit closure and rendered input are different sets. items contains
        /// committed history, never copies of transient suffix injections.
        /// source_request retains the exact prepared request that did contain
        /// those injections, including their real ordering and provenance.
        pub const AdaptiveContext = struct {
            schema: contracts.Text(128),
            policy: [32]u8,
            task: [16]u8,
            tenant: contracts.Text(128),
            audience: contracts.Text(128),
            selection: AdaptiveSelection,
            top_effort: models.ReasoningEffort,
            plan: AdaptivePlan,
            watermark: u64,
            source_capture: ArtifactReference,
            source_request: ArtifactReference,
            response_id: ?contracts.Text(256),
            items: contracts.Bytes(maximum_replay_bytes),
            /// Origin is projection-owned, never inferred from provider text.
            /// It distinguishes injected skill material from identical evidence
            /// and records which responses could have observed an evicted skill.
            origins: contracts.Vector(ContextOrigin, 8192),
        };
        pub const ContextOrigin = struct { watermark: u64, resident_skill: ?u8 = null, reasoning_skills: u32 = 0, reasoning_tools: [declarations.len]bool = @splat(false) };
        pub const AdaptiveResult = struct {
            result: Result,
            replay: ?AdaptiveContextReference,
            replay_status: ReplayStatus,
            usage: ?AdaptiveUsage,
        };

        pub fn allDeclarations() Tools {
            const items = comptime blk: {
                var result: [declarations.len]ToolDeclaration = undefined;
                const info = @typeInfo(Answer).@"union";
                for (declarations, info.field_names, info.field_types, 0..) |descriptor, name, Variant, index| {
                    result[index] = .{
                        .action_ordinal = @intCast(index),
                        .action_tag = @intCast(@backingInt(@field(info.tag_type.?, name))),
                        .name = .{ .bytes = descriptor.name },
                        .description = .{ .bytes = descriptor.description },
                        .input_schema_json = .{ .bytes = &codecs.json.ToolSchema(Variant).value },
                        .strict = true,
                        .argument_codec = CodecProfile.value(index),
                    };
                }
                break :blk result;
            };
            return .{ .items = &items };
        }

        /// Stage immutable fields separately so equal schemas/codecs/descriptions
        /// share canonical constants across distinct model-visible declarations.
        pub fn declarationValue(builder: anytype, index: usize) !u64 {
            if (index >= declarations.len) return error.InvalidDeclarationIndex;
            const slot = try builder.specialization(u64, "agent.model.declaration/v3", .{
                @typeName(Self), index,
            });
            if (slot.cached) |cached| return cached;
            const declaration = allDeclarations().items[index];
            const fields = @typeInfo(ToolDeclaration).@"struct";
            var values: [fields.field_names.len]u64 = undefined;
            inline for (fields.field_names, fields.field_types, 0..) |name, FieldType, field_index| {
                values[field_index] = try builder.literal(.{
                    .schema = try contracts.schema(FieldType, builder),
                    .bytes = try contracts.encodeOwned(FieldType, builder.allocator(), @field(declaration, name)),
                });
            }
            const product = try builder.primitive(try contracts.schema(ToolDeclaration, builder), .product, &values, 0);
            return slot.finish(builder, product);
        }

        /// The returned slice belongs to allocator; nested metadata is immutable.
        pub fn declarationsValue(
            allocator: std.mem.Allocator,
            offered: [declarations.len]bool,
        ) !Tools {
            var count: usize = 0;
            for (offered) |present| if (present) {
                count += 1;
            };
            const items = try allocator.alloc(ToolDeclaration, count);
            var next: usize = 0;
            for (offered, allDeclarations().items) |present, declaration| if (present) {
                items[next] = declaration;
                next += 1;
            };
            return .{ .items = items };
        }

        pub fn parametersValue(comptime Model: type) ModelParameters {
            comptime {
                if (!models.isAdmitted(Model)) @compileError("Protean model must use protean.model");
                if (!std.mem.eql(u8, Model.protocol.semantic_identity, protocol_identity))
                    @compileError("Protean model profile uses an unsupported provider protocol");
                if (Model.model_id.len > limits.model_id_bytes)
                    @compileError("Protean model identifier exceeds model_id_bytes");
            }
            const parameters = Model.parameters;
            const has = @TypeOf(parameters) != void;
            const temperature: ?[]const u8 = if (has and @hasField(@TypeOf(parameters), "temperature"))
                parameters.temperature
            else
                null;
            if (temperature != null and temperature.?.len > limits.temperature_bytes)
                @compileError("Protean model temperature exceeds temperature_bytes");
            return .{
                .max_output_tokens = if (has and @hasField(@TypeOf(parameters), "max_output_tokens"))
                    parameters.max_output_tokens
                else
                    null,
                .temperature = if (temperature) |value| .{ .bytes = value } else null,
                .reasoning = if (has and @hasField(@TypeOf(parameters), "reasoning")) .{
                    .effort = if (@hasField(@TypeOf(parameters.reasoning), "effort"))
                        parameters.reasoning.effort
                    else
                        null,
                    .summary = if (@hasField(@TypeOf(parameters.reasoning), "summary"))
                        parameters.reasoning.summary
                    else
                        null,
                } else null,
            };
        }

        pub fn normalizationLimits() NormalizationLimits {
            return .{
                .maximum_output_items = limits.maximum_output_items,
                .maximum_call_id_bytes = limits.call_id_bytes,
                .maximum_name_bytes = maxima.name,
                .maximum_arguments_bytes = limits.arguments_json_bytes,
                .maximum_argument_name_bytes = @intCast(CodecProfile.FieldName.max_length.?),
                .maximum_argument_fields = @intCast(ArgumentCodec.max_length),
                .maximum_result_text_bytes = limits.result_text_bytes,
            };
        }

        /// Authoring convenience. Dynamic prompt and offer construction uses the
        /// same public product/vector terms inside the emitted computation.
        pub fn invocationValue(
            allocator: std.mem.Allocator,
            comptime Model: type,
            messages: Messages,
            offered: [declarations.len]bool,
            selection: Selection,
        ) !Request {
            var request = try templateValue(Model, messages, selection);
            request.tools = try declarationsValue(allocator, offered);
            return request;
        }

        /// Configuration for the checked responder. Its tools are emitted from
        /// the captured offered set, so the template contains no catalog copy.
        pub fn templateValue(
            comptime Model: type,
            messages: Messages,
            selection: Selection,
        ) !Request {
            if (selection.minimum_calls > selection.maximum_calls or
                selection.maximum_calls > limits.maximum_output_items)
                return error.InvalidSelection;
            return .{
                .protocol = .{ .bytes = protocol_identity },
                .model = .{ .bytes = Model.model_id },
                .parameters = parametersValue(Model),
                .messages = messages,
                .tools = .{ .items = &.{} },
                .selection = selection,
                .response_policy = .{
                    .store = false,
                    .stream = false,
                    .background = false,
                    .truncation = .disabled,
                },
                .normalization_limits = normalizationLimits(),
                .maximum_provider_response_bytes = limits.provider_response_bytes,
            };
        }

        /// A shared ordinary external effect declaration, without a native handler.
        pub fn declare(builder: anytype) !u64 {
            const payload = try contracts.schema(Request, builder);
            const result = try contracts.schema(Result, builder);
            const slot = try builder.specialization(u64, semantic_identity, .{ payload, result });
            if (slot.cached) |cached| return cached;
            const effect = try builder.effect(.{
                .identity = semantic_identity,
                .payload = payload,
                .result = result,
            });
            return slot.finish(builder, effect);
        }

        pub fn declareReplay(builder: anytype) !u64 {
            const payload = try contracts.schema(ReplayRequest, builder);
            const result = try contracts.schema(ReplayResult, builder);
            const slot = try builder.specialization(u64, replay_semantic_identity, .{ payload, result });
            if (slot.cached) |cached| return cached;
            const effect = try builder.effect(.{ .identity = replay_semantic_identity, .payload = payload, .result = result });
            return slot.finish(builder, effect);
        }

        pub fn declareReference(builder: anytype) !u64 {
            const payload = try contracts.schema(ReferenceRequest, builder);
            const result = try contracts.schema(ReferenceResult, builder);
            const slot = try builder.specialization(u64, reference_semantic_identity, .{ payload, result });
            if (slot.cached) |cached| return cached;
            const effect = try builder.effect(.{ .identity = reference_semantic_identity, .payload = payload, .result = result });
            return slot.finish(builder, effect);
        }

        pub fn declareAdaptive(builder: anytype) !u64 {
            const payload = try contracts.schema(AdaptiveRequest, builder);
            const result = try contracts.schema(AdaptiveResult, builder);
            const slot = try builder.specialization(u64, adaptive_semantic_identity, .{ payload, result });
            if (slot.cached) |cached| return cached;
            const effect = try builder.effect(.{ .identity = adaptive_semantic_identity, .payload = payload, .result = result });
            return slot.finish(builder, effect);
        }

        /// Checks the single-answer policy, normalized call association, concrete
        /// variant and request-time offered set. Returns candidate data only.
        pub fn interpreter(builder: anytype) !u64 {
            return @import("model_interpretation.zig").define(Self, builder);
        }

        /// Preserves all admitted candidate calls in their original order.
        /// Candidate count cannot exceed the bounded incoming OutputItems count.
        pub fn interpretAll(builder: anytype) !u64 {
            return @import("model_interpretation.zig").defineAll(Self, builder);
        }
    };
}

/// A question's synthetic answer declaration has no associated executable tool.
pub fn Question(
    comptime Value: type,
    comptime name: []const u8,
    comptime description: []const u8,
    comptime limits: Limits,
) type {
    const Payload = if (@typeInfo(Value) == .@"enum" or
        (@typeInfo(Value) == .@"struct" and !codecs.json.isText(Value)))
        Value
    else
        struct { value: Value };
    const Answer = union(enum) { answer: Payload };
    return Profile(Answer, .{.{ .name = name, .description = description }}, limits);
}
