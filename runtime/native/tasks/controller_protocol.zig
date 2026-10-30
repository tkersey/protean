const std = @import("std");
const contracts = @import("protean_contracts");
const data = @import("horos_data");
const state = @import("../state.zig");
const occurrence = @import("../occurrence.zig");
const storage = @import("../store.zig");
const registry = @import("../registry.zig");
const values = @import("../values.zig");
const workspace = @import("../workspace_state.zig");
const wc = contracts.workspace;
const task_types = @import("types.zig");
const same = task_types.same;

pub fn Operations(comptime Types: type, comptime Self: type) type {
    return struct {
        const controllerAt = Controller.controllerAt;
        const controllerBinding = Controller.controllerBinding;
        const controllerEpochAt = Controller.controllerEpochAt;
        const controllerOverlay = Context.controllerOverlay;
        const controllerSelection = Context.controllerSelection;
        const projectionBinding = Worker.projectionBinding;
        const record = Records.record;
        const requireArchiveRecord = Occurrences.requireArchiveRecord;
        const rootRouteImage = Controller.rootRouteImage;
        const store = Lifecycle.store;
        const Occurrences = @import("archive_occurrences.zig").Operations(Types, Self);
        const Context = @import("controller_context.zig").Operations(Types, Self);
        const Controller = @import("controller_state.zig").Operations(Types, Self);
        const Lifecycle = @import("lifecycle.zig").Operations(Types, Self);
        const Records = @import("records.zig").Operations(Types, Self);
        const Worker = @import("worker_execution.zig").Operations(Types, Self);
        const Programs = @import("workspace_programs.zig").Operations(Types, Self);
        pub fn controllerRequest(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            id: state.Digest,
            request: data.invocation.Request,
        ) !?state.Digest {
            if (parent.controller == null) return null;
            const c = contracts.controller;
            if (same(request.binding.semantic_identity, c.offer_identity)) return id;
            const model = same(request.binding.semantic_identity, c.effect_prefix ++ "deliberate");
            const handoff = same(request.binding.semantic_identity, c.handoff_identity);
            if (!model and !handoff) return null;
            var saved = try record(
                self,
                state.ControllerInteraction,
                a,
                "controller_interaction",
                parent.controller_interaction orelse return error.InvalidControllerBinding,
                parent.id,
            );
            defer saved.deinit();
            if (!std.meta.eql(saved.value.controller, parent.controller.?) or
                saved.value.handoff != null) return error.InvalidControllerBinding;
            const offered = try store(self).object(a, saved.value.offered, null);
            defer a.free(offered);
            if (model) {
                if (saved.value.model != null or !same(offered, request.binding.payload))
                    return error.InvalidControllerBinding;
                saved.value.model = id;
            } else {
                try validateControllerHandoffRequest(
                    self,
                    a,
                    parent,
                    saved.value,
                    request,
                    offered,
                );
                saved.value.handoff = id;
            }
            try store(self).putRecord(
                state.ControllerInteraction,
                "controller_interaction",
                saved.value.id,
                parent.id,
                saved.value,
            );
            return saved.value.id;
        }
        fn validateControllerHandoffRequest(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            interaction: state.ControllerInteraction,
            request: data.invocation.Request,
            offered: []const u8,
        ) !void {
            var prior = try record(
                self,
                occurrence.Occurrence,
                a,
                "occurrence",
                interaction.model orelse return error.InvalidControllerBinding,
                parent.id,
            );
            defer prior.deinit();
            if (prior.value.state != .admitted or prior.value.state.admitted != .reply)
                return error.InvalidControllerBinding;
            const encoded = try store(self).object(
                a,
                try store(self).objectReference(prior.value.state.admitted.reply.reply, null),
                null,
            );
            defer a.free(encoded);
            var reply = try data.invocation.decode(data.invocation.Result, a, encoded);
            defer reply.deinit();
            if (request.binding.payload.len != offered.len + reply.value.value.len or
                !same(request.binding.payload[0..offered.len], offered) or !same(
                request.binding.payload[offered.len..],
                reply.value.value,
            )) return error.InvalidControllerBinding;
        }
        pub fn controllerReply(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            pending: occurrence.Occurrence,
            request: data.invocation.Request,
        ) ![]u8 {
            var route = try record(
                self,
                workspace.ExecutionRoute,
                a,
                "execution_route",
                pending.id,
                parent.id,
            );
            defer route.deinit();
            if (pending.work != null or route.value.controller == null or !std.meta.eql(
                try rootRouteImage(self, a, parent, route.value),
                route.value.image,
            )) return error.InvalidControllerBinding;
            const binding =
                try controllerBinding(self, a, parent, route.value.controller.?);
            if (!std.meta.eql(request.binding.program_identity, binding.program_identity))
                return error.InvalidControllerBinding;
            var program = try self.workspaceProgram(a, parent.id, binding.program);
            defer program.deinit();
            const descriptor = program.value.description.controller.?;
            const model = for (descriptor.imports.items) |item| {
                if (item.import == .deliberate) break item;
            } else return error.InvalidControllerBinding;
            const c = contracts.controller;
            const boot = same(request.binding.semantic_identity, c.boot_identity);
            const offer = same(request.binding.semantic_identity, c.offer_identity);
            if (!boot and !offer and !same(request.binding.semantic_identity, c.handoff_identity))
                return error.InvalidControllerBinding;
            try validateControllerReplySchema(
                self,
                a,
                request,
                program.value.description.input_schema,
                descriptor,
                model,
                boot,
                offer,
            );
            if (boot) {
                if (request.binding.payload.len < parent.id.len or !same(
                    request.binding.payload[0..parent.id.len],
                    &parent.id,
                )) return error.InvalidControllerBinding;
                return a.dupe(u8, &.{});
            }
            if (offer) return controllerOffer(
                self,
                a,
                projectionBinding(self, parent),
                request.binding.payload,
            );
            return controllerHandoffReply(a, request, model.payload.bytes);
        }
        fn controllerHandoffReply(
            a: std.mem.Allocator,
            request: data.invocation.Request,
            payload_schema: []const u8,
        ) ![]u8 {
            var model_schema = try data.schema.decode(a, payload_schema);
            defer model_schema.deinit();
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const scratch = arena.allocator();
            const facts = try data.admission.schemas(scratch, model_schema.descriptor.types);
            var reader: data.wire.Reader = .{ .input = request.binding.payload };
            _ = try data.admission.readValue(
                scratch,
                model_schema.descriptor.types,
                facts,
                model_schema.descriptor.root,
                &reader,
            );
            return std.mem.concat(a, u8, &.{ request.binding.payload[reader.position..], &.{0} });
        }
        fn validateControllerReplySchema(
            self: *Self,
            a: std.mem.Allocator,
            request: data.invocation.Request,
            input_schema: state.Reference,
            descriptor: anytype,
            model: anytype,
            boot: bool,
            offer: bool,
        ) !void {
            const boot_schema =
                if (boot) try store(self).object(a, input_schema, null) else null;
            defer if (boot_schema) |bytes| a.free(bytes);
            const unit = if (boot) try values.schemaBytes(void, a) else null;
            defer if (unit) |bytes| a.free(bytes);
            const payload_schema =
                if (boot)
                    boot_schema.?
                else if (offer)
                    model.payload.bytes
                else
                    descriptor.handoff_payload.bytes;
            const result_schema =
                if (boot)
                    unit.?
                else if (offer)
                    model.payload.bytes
                else
                    (model.public_result orelse return error.InvalidControllerBinding).bytes;
            if (!same(request.binding.payload_schema, payload_schema) or !same(
                request.binding.resume_schema,
                result_schema,
            )) return error.CapabilitySchemaMismatch;
            var shape = try data.schema.decode(a, payload_schema);
            defer shape.deinit();
            try data.schema.validateValue(a, shape.descriptor, request.binding.payload);
        }
        pub fn controllerOffer(
            self: *Self,
            a: std.mem.Allocator,
            binding: registry.ProjectionBinding,
            payload: []const u8,
        ) ![]u8 {
            var entry = for (self.handlers.entries) |item| {
                if (item.declaration.controller_import == .deliberate) break item;
            } else return error.MissingCapability;
            entry.controller_envelope = true;
            const proposal = try entry.payload(a, payload);
            const callback = entry.declaration.controller_offer orelse return a.dupe(u8, payload);
            const normalized =
                try store(self).project([]u8, a, self.handlers, binding, struct {
                    callback: @TypeOf(callback),
                    proposal: []const u8,
                    pub fn run(this: @This(), context: registry.ProjectionContext) ![]u8 {
                        return this.callback(context, this.proposal);
                    }
                }{ .callback = callback, .proposal = proposal });
            defer a.free(normalized);
            return std.mem.concat(a, u8, &.{ normalized, payload[proposal.len..] });
        }
        pub fn controllerStoredReply(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            pending: occurrence.Occurrence,
            request: data.invocation.Request,
        ) ![]u8 {
            const ordinary = try controllerReply(self, a, parent, pending, request);
            errdefer a.free(ordinary);
            if (!same(request.binding.semantic_identity, contracts.controller.handoff_identity))
                return ordinary;
            const selected = (try controllerSelection(
                self,
                a,
                parent,
                ordinary[0 .. ordinary.len - 1],
            )) orelse return ordinary;
            var route = try record(
                self,
                workspace.ExecutionRoute,
                a,
                "execution_route",
                pending.id,
                parent.id,
            );
            defer route.deinit();
            const id = route.value.interaction orelse return error.InvalidArchive;
            const bytes = (try store(self).recordBytes(
                a,
                "controller_succession",
                id,
                parent.id,
            )) orelse return ordinary;
            defer a.free(bytes);
            var succession = try contracts.decodeOwned(state.ControllerSuccession, a, bytes);
            defer succession.deinit();
            const command = try contracts.encodeOwned(wc.Adoption, a, selected);
            defer a.free(command);
            if (!std.meta.eql(succession.value.command, state.Reference{
                .digest = storage.digest(command),
                .bytes = command.len,
            })) return error.InvalidArchive;
            if (succession.value.phase == .activated) return error.InvalidArchive;
            const diagnostic = succession.value.diagnostic orelse return error.InvalidArchive;
            const encoded =
                try contracts.encodeOwned(?contracts.controller.Diagnostic, a, diagnostic);
            defer a.free(encoded);
            const result =
                try std.mem.concat(a, u8, &.{
                    ordinary[0 .. ordinary.len - 1],
                    encoded,
                });
            a.free(ordinary);
            return result;
        }
        pub fn validateControllerInteraction(
            self: *Self,
            allocator: std.mem.Allocator,
            parent: state.Task,
            id: state.Digest,
            records: []const state.ArchiveRecord,
        ) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var saved = try record(
                self,
                state.ControllerInteraction,
                a,
                "controller_interaction",
                id,
                parent.id,
            );
            defer saved.deinit();
            const interaction = saved.value;
            try validateControllerInteractionIdentity(self, a, parent, id, interaction);
            const offered =
                try controllerInteractionOffered(self, a, parent, id, interaction, records);
            try validateControllerInteractionCarry(self, a, parent, id, interaction, offered);
            var model_reply: ?[]const u8 = null;
            inline for (.{ "model", "handoff" }) |field|
                if (@field(interaction, field)) |occurrence_id| {
                    try validateControllerInteractionOccurrence(
                        self,
                        a,
                        parent,
                        id,
                        interaction,
                        records,
                        offered,
                        field,
                        occurrence_id,
                        &model_reply,
                    );
                };
        }
        fn validateControllerInteractionOccurrence(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            id: state.Digest,
            interaction: state.ControllerInteraction,
            records: []const state.ArchiveRecord,
            offered: []const u8,
            comptime field: []const u8,
            occurrence_id: state.Digest,
            model_reply: *?[]const u8,
        ) !void {
            try validateControllerInteractionRoute(
                self,
                a,
                parent,
                id,
                interaction,
                records,
                occurrence_id,
            );
            var pending =
                try record(self, occurrence.Occurrence, a, "occurrence", occurrence_id, parent.id);
            defer pending.deinit();
            var request = try data.invocation.decode(
                data.invocation.Request,
                a,
                try store(self).object(a, pending.value.request_object, null),
            );
            defer request.deinit();
            const is_model = comptime same(field, "model");
            if (!same(
                request.value.binding.semantic_identity,
                if (is_model)
                    contracts.controller.effect_prefix ++ "deliberate"
                else
                    contracts.controller.handoff_identity,
            )) return error.InvalidArchive;
            try validateControllerInteractionPayload(
                self,
                a,
                interaction,
                pending.value,
                request.value,
                offered,
                is_model,
                model_reply,
            );
        }
        fn validateControllerInteractionPayload(
            self: *Self,
            a: std.mem.Allocator,
            interaction: state.ControllerInteraction,
            pending: occurrence.Occurrence,
            request: data.invocation.Request,
            offered: []const u8,
            comptime is_model: bool,
            model_reply: *?[]const u8,
        ) !void {
            if (is_model) {
                if (!same(request.binding.payload, offered)) return error.InvalidArchive;
                if (interaction.handoff != null) {
                    const result = switch (pending.state) {
                        .admitted => |outcome| if (outcome ==
                            .reply) outcome.reply else return error.InvalidArchive,
                        else => return error.InvalidArchive,
                    };
                    var decoded = try data.invocation.decode(
                        data.invocation.Result,
                        a,
                        try store(self).object(
                            a,
                            try store(self).objectReference(result.reply, null),
                            null,
                        ),
                    );
                    defer decoded.deinit();
                    model_reply.* = try a.dupe(u8, decoded.value.value);
                }
            } else {
                const result = model_reply.* orelse return error.InvalidArchive;
                const payload = request.binding.payload;
                if (payload.len != offered.len + result.len or !same(
                    payload[0..offered.len],
                    offered,
                ) or !same(payload[offered.len..], result)) return error.InvalidArchive;
            }
        }
        fn validateControllerInteractionRoute(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            id: state.Digest,
            interaction: state.ControllerInteraction,
            records: []const state.ArchiveRecord,
            occurrence_id: state.Digest,
        ) !void {
            try requireArchiveRecord(records, .occurrence, occurrence_id);
            try requireArchiveRecord(records, .execution_route, occurrence_id);
            var route = try record(
                self,
                workspace.ExecutionRoute,
                a,
                "execution_route",
                occurrence_id,
                parent.id,
            );
            defer route.deinit();
            if (route.value.work != null or !std.meta.eql(
                route.value.controller,
                interaction.controller,
            ) or !std.meta.eql(route.value.interaction, id)) return error.InvalidArchive;
        }
        fn validateControllerInteractionCarry(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            id: state.Digest,
            interaction: state.ControllerInteraction,
            offered: []const u8,
        ) !void {
            var entry = for (self.handlers.entries) |item| {
                if (item.declaration.controller_import == .deliberate) break item;
            } else return error.InvalidArchive;
            entry.controller_envelope = true;
            const proposed = try entry.payload(a, offered);
            const carry = try store(self).object(a, interaction.carry, null);
            if (!same(carry, offered[proposed.len..])) return error.InvalidArchive;
            const overlay = try controllerOverlay(
                self,
                a,
                parent,
                interaction.controller,
                id,
                interaction.event_cut,
                interaction.next_message,
                interaction.epoch,
            );
            if (!same(overlay, try store(self).object(a, interaction.overlay, null)))
                return error.InvalidArchive;
        }
        fn controllerInteractionOffered(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            id: state.Digest,
            interaction: state.ControllerInteraction,
            records: []const state.ArchiveRecord,
        ) ![]const u8 {
            try requireArchiveRecord(records, .occurrence, id);
            var offer =
                try record(self, occurrence.Occurrence, a, "occurrence", id, parent.id);
            defer offer.deinit();
            try requireArchiveRecord(records, .execution_route, id);
            var offer_route =
                try record(self, workspace.ExecutionRoute, a, "execution_route", id, parent.id);
            defer offer_route.deinit();
            if (offer_route.value.work != null or !std.meta.eql(
                offer_route.value.controller,
                interaction.controller,
            ) or !std.meta.eql(offer_route.value.interaction, id)) return error.InvalidArchive;
            var offer_request = try data.invocation.decode(
                data.invocation.Request,
                a,
                try store(self).object(a, offer.value.request_object, null),
            );
            defer offer_request.deinit();
            if (!same(
                offer_request.value.binding.semantic_identity,
                contracts.controller.offer_identity,
            )) return error.InvalidArchive;
            const accepted = switch (offer.value.state) {
                .settled_reply => |reply| reply,
                .admitted => |outcome| if (outcome ==
                    .reply) outcome.reply else return error.InvalidArchive,
                else => return error.InvalidArchive,
            };
            const reply_bytes = try store(self).object(
                a,
                try store(self).objectReference(accepted.reply, null),
                null,
            );
            var reply = try data.invocation.decode(data.invocation.Result, a, reply_bytes);
            defer reply.deinit();
            const offered = try store(self).object(a, interaction.offered, null);
            if (!same(offered, reply.value.value)) return error.InvalidArchive;
            return offered;
        }
        fn validateControllerInteractionIdentity(
            self: *Self,
            a: std.mem.Allocator,
            parent: state.Task,
            id: state.Digest,
            interaction: state.ControllerInteraction,
        ) !void {
            if (!std.meta.eql(interaction.id, id) or
                !std.meta.eql(interaction.task, parent.id) or
                !std.meta.eql(interaction.policy, parent.profile) or
                interaction.next_message > parent.next_message or !std.meta.eql(
                @as(?state.Digest, interaction.controller),
                try controllerAt(self, a, parent, interaction.event_cut),
            ) or interaction.epoch != try controllerEpochAt(
                self,
                a,
                parent,
                interaction.event_cut,
            )) return error.InvalidArchive;
            const binding =
                try controllerBinding(self, a, parent, interaction.controller);
            var program = try self.workspaceProgram(a, parent.id, binding.program);
            defer program.deinit();
            const schema = program.value.description.controller.?.carry.bytes;
            if (!std.meta.eql(interaction.carry_schema.digest, storage.digest(schema)) or
                interaction.carry_schema.bytes != schema.len) return error.InvalidArchive;
        }
    };
}
