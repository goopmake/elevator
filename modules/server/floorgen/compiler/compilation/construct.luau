--!strict
--[[
	Graph construction.

	Builds the execution graph from parsed and resolved definitions.

	A compiled node is a *specialisation* of a definition: the definition plus
	the behaviour keys of its effective configuration. A reference without
	behaviour overrides reuses its target's node; one with behaviour overrides
	gets its own node sharing the target's children. Use-site keys (placement,
	weight, optional, recursion limit, connection use) live on edges, and the
	room / plug roles live on assemblies, so one node can be used from many
	places.

	Construction is a deterministic worklist starting at the root. Children are
	processed in authored order, so node, registry and counter ids are stable
	for equivalent inputs. Recursive references point back at existing nodes;
	nothing is inlined.

	Construction never stops at the first problem. A child that cannot be built
	is reported and left out, and its parent is marked incomplete so that checks
	depending on the full child list do not cascade.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = require(ReplicatedStorage.shared.modules.result)

local constants = require(script.Parent.Parent.constants)
local diagnostics = require(script.Parent.Parent.diagnostics)
local ir = require(script.Parent.Parent.ir)
local types = require(script.Parent.Parent.types)
local stream = require(script.Parent.Parent.stream)
local registryModule = require(script.Parent.Parent.registry)
local resolution = require(script.Parent.Parent.resolution)
local attributes = require(script.Parent.Parent.validation.attributes)
local models = require(script.Parent.Parent.validation.models)
local spatial = require(script.Parent.Parent.validation.spatial)
local structure = require(script.Parent.Parent.validation.structure)

type session = ir.session
type definition = ir.definition
type node_config = ir.node_config
type parsed_config = ir.parsed_config
type node_kind = ir.node_kind
type child = ir.child
type edge_draft = ir.edge_draft
type node_draft = ir.node_draft
type graph = ir.graph
type outcome<T> = diagnostics.outcome<T>
type registry = registryModule.registry

local errors = diagnostics.codes.errors
local warningCodes = diagnostics.codes.warnings

type builder = {
	session: session,
	registry: registry,
	spatial: spatial.state,
	nodes: { node_draft },
	byKey: { [string]: number },
	queue: { number },
	-- Definition id -> counter id.
	counters: { [number]: number },
	counterCount: number,
}

local function sourceOfDefinition(def: definition): types.source_info
	return table.freeze({ label = def.label, path = def.path, className = def.className })
end

local function sourceOfReference(ref: ir.reference_use): types.source_info
	return table.freeze({ label = ref.label, path = ref.path, className = ref.instance.ClassName })
end

local function warnInto(session: session): (diagnostics.diagnostic) -> ()
	return function(d)
		diagnostics.report(session.sink, d)
	end
end

-- Configuration ---------------------------------------------------------------

-- Validated own configuration of a definition. Memoised: errors are reported
-- to the sink by the first call; later calls fail with an empty list.
local function ownConfig(session: session, def: definition): outcome<parsed_config>
	local memo = session.ownConfigs[def.id]
	if type(memo) == "table" then
		return result.ok(memo)
	elseif memo == false then
		return result.err({})
	end
	local problems: { diagnostics.diagnostic }
	local parsed = attributes.parse(def.kind, def.ownConfig, def.instance, true, false, warnInto(session))
	if parsed.ok then
		local checked = attributes.crossCheck(def.kind, parsed.val.config, def.instance)
		if checked.ok then
			session.ownConfigs[def.id] = parsed.val
			return parsed
		end
		problems = checked.err
	else
		problems = parsed.err
	end
	session.ownConfigs[def.id] = false
	diagnostics.reportAll(session.sink, problems)
	return result.err({})
end

-- Effective configuration of a reference: the target's configuration with the
-- reference's keys layered on top. Memoised like ownConfig.
local function referenceConfig(session: session, ref: ir.reference_use, target: definition): outcome<parsed_config>
	if not resolution.hasKeys(ref.ownConfig) then
		return ownConfig(session, target)
	end
	local memo = session.referenceConfigs[ref.instance]
	if type(memo) == "table" then
		return result.ok(memo)
	elseif memo == false then
		return result.err({})
	end

	local function failed(list: { diagnostics.diagnostic }): outcome<parsed_config>
		session.referenceConfigs[ref.instance] = false
		diagnostics.reportAll(session.sink, list)
		return result.err({})
	end

	local overrides = resolution.hasBehaviourOverrides(ref.ownConfig)
	if overrides then
		-- Computed from the raw keys so it is reported even if parsing fails.
		local removed = {}
		for _, name in target.ownConfig.attributeNames do
			if constants.BEHAVIOUR_KEYS[name] and ref.ownConfig.attributes[name] == nil then
				table.insert(removed, name)
			end
		end
		for _, tag in target.ownConfig.tags do
			if constants.BEHAVIOUR_KEYS[tag] and table.find(ref.ownConfig.tags, tag) == nil then
				table.insert(removed, tag)
			end
		end
		if #removed > 0 then
			diagnostics.warn(
				session.sink,
				warningCodes.OVERRIDE_REMOVES_KEYS,
				ref.instance,
				string.format(
					"This reference overrides its target's behaviour, so these target keys are removed: %s.",
					table.concat(removed, ", ")
				),
				{
					hint = "A behaviour override must be complete: restate every behaviour key you want to keep.",
				}
			)
		end
	end

	local targetConfig = ownConfig(session, target)
	if not targetConfig.ok then
		return failed({})
	end
	local own = attributes.parse(target.kind, ref.ownConfig, ref.instance, overrides, true, warnInto(session))
	if not own.ok then
		return failed(own.err)
	end

	local effective = attributes.layer(targetConfig.val, own.val, overrides)
	local checked = attributes.crossCheck(target.kind, effective.config, ref.instance)
	if not checked.ok then
		return failed(checked.err)
	end
	session.referenceConfigs[ref.instance] = effective
	return result.ok(effective)
end

-- Nodes -----------------------------------------------------------------------

local function signature(kind: node_kind, config: node_config): string
	local count = if config.maxCount then tostring(config.maxCount) else "-"
	if kind == "assembly" then
		return count
	elseif kind == "model" then
		return string.format("%s/%s", tostring(config.conditional), count)
	elseif kind == "pick" then
		return string.format(
			"%s/%s/%s/%s",
			tostring(config.pickMin),
			tostring(config.pickMax),
			tostring(config.pickUnique),
			config.pickMode
		)
	end
	return ""
end

-- Facts of a model definition (see validation/models for the memoisation).
local function modelFacts(b: builder, def: definition): outcome<ir.model_facts>
	local instance = def.instance
	if not instance:IsA("Model") then
		return diagnostics.fail(errors.INTERNAL_INVARIANT, instance, "A model definition is not a Model.")
	end
	return models.inspect(b.session, instance)
end

-- Registers a model definition and checks its conditional requirements.
local function prepareModel(b: builder, def: definition, config: node_config): outcome<number>
	local facts = modelFacts(b, def)
	if not facts.ok then
		return facts
	end
	if config.conditional then
		local checked = models.checkConditional(facts.val)
		if not checked.ok then
			return checked
		end
	end
	local registered = registryModule.register(b.registry, facts.val)
	if registered.ok and config.conditional then
		registryModule.markConditional(b.registry, registered.val)
	end
	return registered
end

-- Counters are shared by all specialisations of one definition.
local function counterOf(b: builder, def: definition): number
	local existing = b.counters[def.id]
	if existing then
		return existing
	end
	b.counterCount += 1
	b.counters[def.id] = b.counterCount
	return b.counterCount
end

-- Returns the node for (definition, behaviour), creating it if needed.
local function specialize(b: builder, def: definition, config: node_config): outcome<number>
	local key = string.format("%d|%s", def.id, signature(def.kind, config))
	local existing = b.byKey[key]
	if existing then
		return result.ok(existing)
	end

	local modelId: number? = nil
	if def.kind == "model" then
		local prepared = prepareModel(b, def, config)
		if not prepared.ok then
			return prepared
		end
		modelId = prepared.val
	end

	local id = #b.nodes + 1
	local draft: node_draft = {
		id = id,
		kind = def.kind,
		definition = def,
		config = config,
		source = sourceOfDefinition(def),
		edges = {},
		plugs = {},
		complete = def.complete,
		room = nil,
		model = modelId,
		counter = if config.maxCount ~= nil then counterOf(b, def) else nil,
		totalWeight = 0,
		mayFail = false,
	}
	table.insert(b.nodes, draft)
	b.byKey[key] = id
	if def.kind ~= "model" then
		table.insert(b.queue, id)
	end
	return result.ok(id)
end

-- Children --------------------------------------------------------------------

type resolved_child = {
	target: definition,
	config: node_config,
	instance: Instance,
	isReference: boolean,
	source: types.source_info,
	-- Stable stream key (see stream.luau).
	key: number,
}

local function resolveChild(b: builder, c: child, keyText: string): outcome<resolved_child>
	local key = stream.hashString(keyText)
	if c.kind == "inline" then
		local target = b.session.definitions[c.definition]
		local parsed = ownConfig(b.session, target)
		if not parsed.ok then
			return parsed
		end
		local resolved: resolved_child = {
			target = target,
			config = parsed.val.config,
			instance = c.instance,
			isReference = false,
			source = sourceOfDefinition(target),
			key = key,
		}
		return result.ok(resolved)
	end

	local ref = c.reference
	local targetId = resolution.targetOf(b.session, ref)
	if targetId == nil then
		-- Reported by the resolution stage.
		return result.err({})
	end
	local target = b.session.definitions[targetId]
	local parsed = referenceConfig(b.session, ref, target)
	if not parsed.ok then
		return parsed
	end
	local instance: Instance = ref.instance
	local resolved: resolved_child = {
		target = target,
		config = parsed.val.config,
		instance = instance,
		isReference = true,
		source = sourceOfReference(ref),
		key = key,
	}
	return result.ok(resolved)
end

-- Pivot model of a placed child, used for fb_anchor.
local function pivotOf(b: builder, target: definition): spatial.pivot_lookup
	if target.kind == "model" then
		local facts = modelFacts(b, target)
		if facts.ok then
			return { kind = "ok", facts = facts.val }
		end
		return { kind = "invalid" }
	elseif target.kind == "assembly" then
		return spatial.roomPivot(b.spatial, target.instance)
	end
	return { kind = "none" }
end

-- The anchor connection consumed in the child's own scope (assemblies only).
local function anchorOf(rc: resolved_child): string?
	if rc.target.kind == "assembly" then
		return rc.config.anchor
	end
	return nil
end

local function computePlacement(b: builder, parent: node_draft, rc: resolved_child): outcome<CFrame>
	local target = rc.target
	if target.kind == "try" or target.kind == "pick" or target.kind == "each" then
		-- Spatially transparent; configuration validation rejects fb_attach here.
		return result.ok(CFrame.identity)
	end

	local config = rc.config
	if config.attach then
		return spatial.attachPlacement(
			b.spatial,
			rc.instance,
			parent.definition.instance,
			config.attach,
			config.anchor,
			pivotOf(b, target)
		)
	end

	if config.anchor then
		return diagnostics.fail(
			errors.ANCHOR_WITHOUT_ATTACH,
			rc.instance,
			"fb_anchor only has an effect together with fb_attach (or on the child of an each node, or on a plug).",
			{ attribute = constants.ATTRIBUTE.anchor, hint = "Add fb_attach naming the parent connection, or remove fb_anchor." }
		)
	end

	if config.room then
		-- The room is the assembly's pivot.
		return result.ok(CFrame.identity)
	end

	if target.kind == "assembly" then
		local room = spatial.findRoom(b.spatial, target.instance)
		if room.kind == "none" then
			-- An assembly without a room shares its parent's frame.
			return result.ok(CFrame.identity)
		elseif room.kind == "ambiguous" then
			-- Reported as ROOM_DUPLICATE on the assembly itself.
			return result.ok(CFrame.identity)
		end
	end

	if not rc.isReference then
		local parentFrame = spatial.authoringFrame(b.spatial, parent.definition.instance)
		local childFrame: CFrame? = nil
		if target.kind == "model" then
			local facts = modelFacts(b, target)
			childFrame = if facts.ok then facts.val.pivot else nil
		else
			childFrame = spatial.authoringFrame(b.spatial, target.instance)
		end
		local authored = spatial.authoredPlacement(parentFrame, childFrame)
		if authored then
			return result.ok(authored)
		end
		local reason = if childFrame == nil
			then "this assembly's own room is a reference, so it has no authored position"
			else "the enclosing assembly's room is a reference, so there is no authored frame to measure from"
		diagnostics.warn(
			b.session.sink,
			warningCodes.PLACEMENT_UNAVAILABLE,
			rc.instance,
			string.format("The authored placement cannot be derived (%s); it is placed at the enclosing pivot.", reason),
			{
				hint = if spatial.hasAttachmentRoom(b.spatial, parent.definition.instance)
					then "Use fb_attach with a connection Attachment on the enclosing room."
					else "Use an inline room model if the authored position matters.",
			}
		)
		return result.ok(CFrame.identity)
	end

	if not spatial.hasAttachmentRoom(b.spatial, parent.definition.instance) then
		-- Nothing to attach to: placing the pivot at the enclosing frame is the
		-- only possible meaning (e.g. a room referenced from a roomless root).
		return result.ok(CFrame.identity)
	end
	diagnostics.warn(
		b.session.sink,
		warningCodes.PLACEMENT_AT_PIVOT,
		rc.instance,
		"This reference has no fb_attach, so its pivot is placed exactly at the enclosing frame.",
		{ hint = "Add fb_attach naming a connection on the enclosing room." }
	)
	return result.ok(CFrame.identity)
end

local function newEdge(rc: resolved_child, nodeId: number, placement: CFrame, connection: string?): edge_draft
	return {
		node = nodeId,
		placement = placement,
		recursive = false,
		maxDepth = rc.config.maxDepth,
		optional = rc.config.optional,
		connection = connection,
		anchor = anchorOf(rc),
		contested = false,
		mayFail = false,
		key = rc.key,
		source = rc.source,
		instance = rc.instance,
		isReference = rc.isReference,
		weight = rc.config.pickWeight or 1,
	}
end

local function matchesFilter(name: string, filter: string?): boolean
	return filter == nil or string.sub(name, 1, #filter) == filter
end

-- Key text of a child: its name plus its occurrence among same-named siblings.
local function keyTexts(def: definition): { string }
	local seen: { [string]: number } = {}
	local texts = {}
	for _, c in def.children do
		local name = c.instance.Name
		seen[name] = (seen[name] or 0) + 1
		table.insert(texts, string.format("%s#%d", name, seen[name]))
	end
	return texts
end

-- Builds the slots of an each node: its single child placed once per matching
-- connection of the enclosing room.
local function buildEach(b: builder, draft: node_draft)
	local def = draft.definition
	local sink = b.session.sink

	if #def.children ~= 1 then
		if def.complete then
			diagnostics.report(
				sink,
				diagnostics.makeError(
					errors.EACH_CHILD_COUNT,
					def.instance,
					string.format("An each node needs exactly one child, found %d.", #def.children),
					{ hint = "Put the per-connection content in a single assembly, model or reference." }
				)
			)
		end
		draft.complete = false
		return
	end

	local texts = keyTexts(def)
	local resolved = resolveChild(b, def.children[1], texts[1])
	if not resolved.ok then
		diagnostics.reportAll(sink, resolved.err)
		draft.complete = false
		return
	end
	local rc = resolved.val
	local problems = {}
	if rc.target.kind ~= "assembly" and rc.target.kind ~= "model" then
		table.insert(
			problems,
			diagnostics.makeError(
				errors.EACH_CHILD_KIND,
				rc.instance,
				string.format("The child of an each node is placed on connections, so it must be an assembly or model, not a %s.", rc.target.kind),
				{ hint = "Wrap it in an 'asm <label>' Configuration." }
			)
		)
	end
	if rc.config.attach then
		table.insert(
			problems,
			diagnostics.makeError(
				errors.EACH_CHILD_ATTACHED,
				rc.instance,
				"The child of an each node is attached to each connection automatically and cannot use fb_attach.",
				{ attribute = constants.ATTRIBUTE.attach, hint = "Remove fb_attach; use fb_filter on the each node to choose connections." }
			)
		)
	end
	if rc.config.room or rc.config.plug then
		table.insert(
			problems,
			diagnostics.makeError(
				errors.EACH_CHILD_KIND,
				rc.instance,
				"The child of an each node cannot be a room or a plug."
			)
		)
	end
	local assembly = spatial.attachmentAssembly(def.instance)
	local room: spatial.pivot_lookup = if assembly then spatial.roomPivot(b.spatial, assembly) else { kind = "none" }
	if room.kind == "none" or room.kind == "ambiguous" then
		table.insert(
			problems,
			diagnostics.makeError(
				errors.ATTACH_NO_ROOM,
				def.instance,
				"An each node iterates the connections of the enclosing assembly's room, but there is no single room.",
				{ hint = "Tag exactly one direct child model of the enclosing assembly with fb_room." }
			)
		)
	end
	if #problems > 0 then
		diagnostics.reportAll(sink, problems)
		draft.complete = false
		return
	end
	if room.kind ~= "ok" then
		-- Invalid room: already reported by model inspection.
		draft.complete = false
		return
	end

	local nodeId = specialize(b, rc.target, rc.config)
	if not nodeId.ok then
		diagnostics.reportAll(sink, nodeId.err)
		draft.complete = false
		return
	end

	local pivot = pivotOf(b, rc.target)
	for _, connection in room.facts.connections do
		if not matchesFilter(connection.name, draft.config.filter) then
			continue
		end
		local placement = spatial.matePlacement(rc.instance, connection.offset, rc.config.anchor, pivot)
		if not placement.ok then
			diagnostics.reportAll(sink, placement.err)
			draft.complete = false
			return
		end
		local edge = newEdge(rc, nodeId.val, placement.val, connection.name)
		edge.key = stream.hashString(texts[1] .. "@" .. connection.name)
		table.insert(draft.edges, edge)
	end

	if #draft.edges == 0 then
		diagnostics.warn(
			sink,
			warningCodes.FILTER_MATCHES_NOTHING,
			def.instance,
			string.format("No connection of %s matches this each node, so it never emits anything.", room.facts.path),
			{ attribute = constants.ATTRIBUTE.filter }
		)
	end
end

-- Builds the plug edges of an assembly: for every room connection, the first
-- plug (in authored order) whose filter matches it.
local function buildPlugs(b: builder, draft: node_draft, plugs: { resolved_child })
	if #plugs == 0 then
		return
	end
	local sink = b.session.sink
	local room = spatial.roomPivot(b.spatial, draft.definition.instance)
	if room.kind ~= "ok" then
		-- Missing rooms are reported by checkPlugPosition, invalid ones by
		-- model inspection, duplicates as ROOM_DUPLICATE.
		return
	end

	local used: { [resolved_child]: boolean } = {}
	for _, connection in room.facts.connections do
		for _, rc in plugs do
			if not matchesFilter(connection.name, rc.config.filter) then
				continue
			end
			used[rc] = true
			local nodeId = specialize(b, rc.target, rc.config)
			local placement = spatial.matePlacement(rc.instance, connection.offset, rc.config.anchor, pivotOf(b, rc.target))
			if not nodeId.ok or not placement.ok then
				if not nodeId.ok then
					diagnostics.reportAll(sink, nodeId.err)
				end
				if not placement.ok then
					diagnostics.reportAll(sink, placement.err)
				end
				draft.complete = false
				return
			end
			local edge = newEdge(rc, nodeId.val, placement.val, connection.name)
			edge.key = stream.hashString(string.format("%d@%s", rc.key, connection.name))
			table.insert(draft.plugs, edge)
			break
		end
	end

	for _, rc in plugs do
		if not used[rc] then
			diagnostics.warn(
				sink,
				warningCodes.FILTER_MATCHES_NOTHING,
				rc.instance,
				"This plug matches no room connection that an earlier plug does not already seal.",
				{ attribute = constants.ATTRIBUTE.filter }
			)
		end
	end
end

local function buildEdges(b: builder, draft: node_draft)
	if draft.kind == "each" then
		buildEach(b, draft)
		return
	end

	local def = draft.definition
	local sink = b.session.sink
	local texts = keyTexts(def)
	local plugs: { resolved_child } = {}
	local hasRoom = draft.kind == "assembly" and spatial.findRoom(b.spatial, def.instance).kind ~= "none"

	for index, c in def.children do
		local resolved = resolveChild(b, c, texts[index])
		if not resolved.ok then
			diagnostics.reportAll(sink, resolved.err)
			draft.complete = false
			continue
		end
		local rc = resolved.val

		local problems = {}
		if draft.kind == "pick" then
			local checked = structure.checkPickCandidate(rc.target.kind, rc.instance)
			if not checked.ok then
				table.move(checked.err, 1, #checked.err, #problems + 1, problems)
			end
		end
		local room = structure.checkRoomPosition(rc.config, draft.kind, rc.instance)
		if not room.ok then
			table.move(room.err, 1, #room.err, #problems + 1, problems)
		end
		local plug = structure.checkPlugPosition(rc.config, draft.kind, hasRoom, rc.instance)
		if not plug.ok then
			table.move(plug.err, 1, #plug.err, #problems + 1, problems)
		end
		if #problems > 0 then
			diagnostics.reportAll(sink, problems)
			draft.complete = false
			continue
		end

		if rc.config.pickWeight ~= nil and draft.kind ~= "pick" then
			diagnostics.warn(
				sink,
				warningCodes.PICK_WEIGHT_UNUSED,
				rc.instance,
				"fb_pick_weight has no effect here because this is not a pick candidate.",
				{ attribute = constants.ATTRIBUTE.pickWeight }
			)
		end

		if rc.config.plug then
			table.insert(plugs, rc)
			continue
		end

		local nodeId = specialize(b, rc.target, rc.config)
		local placement = computePlacement(b, draft, rc)
		if not nodeId.ok or not placement.ok then
			if not nodeId.ok then
				diagnostics.reportAll(sink, nodeId.err)
			end
			if not placement.ok then
				diagnostics.reportAll(sink, placement.err)
			end
			draft.complete = false
			continue
		end

		table.insert(draft.edges, newEdge(rc, nodeId.val, placement.val, rc.config.attach))
	end

	if draft.kind == "assembly" then
		local room = spatial.findRoom(b.spatial, def.instance)
		local unique = structure.checkRoomUnique(room, def.instance)
		if not unique.ok then
			diagnostics.reportAll(sink, unique.err)
		else
			local facts = spatial.roomFacts(b.spatial, def.instance)
			if facts then
				draft.room = b.registry.idOf[facts.model]
			end
		end
		buildPlugs(b, draft, plugs)
	elseif draft.kind == "pick" then
		local amountMax = draft.config.pickMax
		if amountMax ~= nil and draft.complete then
			local weights = {}
			for _, e in draft.edges do
				table.insert(weights, e.weight)
			end
			local selection = structure.checkPickSelection(def.instance, amountMax, draft.config.pickUnique, weights)
			local total = diagnostics.absorb(sink, selection)
			if total then
				draft.totalWeight = total
			end
		end
		if amountMax == 0 then
			diagnostics.warn(
				sink,
				warningCodes.PICK_AMOUNT_ZERO,
				def.instance,
				"fb_pick_amount is 0, so this pick never emits anything.",
				{ attribute = constants.ATTRIBUTE.pickAmount }
			)
		end
	end
end

-- Connection scopes -------------------------------------------------------------

local TRANSPARENT: { [node_kind]: boolean } = table.freeze({ try = true, pick = true, each = true })

-- Whether a transparent node (and transparent nodes below it) consumes
-- connections. Such nodes belong to the scope of their enclosing assembly and
-- must not be used through references.
local function consumesConnections(g: graph, id: number, visited: { [number]: boolean }): boolean
	if visited[id] then
		return false
	end
	visited[id] = true
	local node = g.nodes[id]
	for _, edge in node.edges do
		if edge.connection ~= nil then
			return true
		end
		local target = g.nodes[edge.node]
		if TRANSPARENT[target.kind] and consumesConnections(g, edge.node, visited) then
			return true
		end
	end
	return false
end

local function checkScopes(b: builder, g: graph)
	for _, node in g.nodes do
		for _, edge in node.edges do
			local target = g.nodes[edge.node]
			if edge.isReference and TRANSPARENT[target.kind] and consumesConnections(g, edge.node, {}) then
				diagnostics.report(
					b.session.sink,
					diagnostics.makeError(
						errors.ATTACH_SCOPE,
						edge.instance,
						string.format(
							"The referenced %s node uses connections of the room it was written in, so it cannot be used elsewhere.",
							target.kind
						),
						{ hint = "Reference the enclosing assembly instead, or copy the node." }
					)
				)
			end
		end
	end
end

type site = {
	edge: edge_draft,
	-- (node id, edge index) pairs from the scope's assembly down to the edge.
	path: { { node: number, branch: number } },
	-- Each slots skip consumed connections, so they never fail themselves.
	dynamic: boolean,
}

-- Whether a pick may select more than one candidate in one execution.
local function selectsSeveral(node: node_draft): boolean
	return (node.config.pickMax or 0) >= 2
end

local function exclusive(g: graph, a: site, b: site): boolean
	local length = math.min(#a.path, #b.path)
	for i = 1, length do
		local stepA, stepB = a.path[i], b.path[i]
		if stepA.branch ~= stepB.branch then
			local node = g.nodes[stepA.node]
			if node.kind == "try" then
				return true
			elseif node.kind == "pick" then
				return not selectsSeveral(node)
			end
			return false
		end
	end
	return false
end

-- Whether a dynamic (each) site can run before an explicit site. Children of
-- an assembly run in authored order; pick selections run in random order.
local function mayRunBefore(g: graph, dynamic: site, explicit: site): boolean
	local length = math.min(#dynamic.path, #explicit.path)
	for i = 1, length do
		local stepD, stepE = dynamic.path[i], explicit.path[i]
		if stepD.branch ~= stepE.branch then
			local node = g.nodes[stepD.node]
			if node.kind == "assembly" then
				return stepD.branch < stepE.branch
			elseif node.kind == "try" then
				return false
			elseif node.kind == "pick" then
				return selectsSeveral(node)
			end
			return true
		end
	end
	return true
end

-- Whether one site can be executed twice in the same scope.
local function repeats(g: graph, s: site): boolean
	for _, step in s.path do
		local node = g.nodes[step.node]
		if node.kind == "pick" and selectsSeveral(node) and not node.config.pickUnique then
			return true
		end
	end
	return false
end

--[[
	Marks edges whose connection may already be consumed when they run.

	Within one assembly scope, two connection uses conflict unless they are
	alternatives of the same try, or candidates of a pick that selects at most
	one. A use also conflicts with itself when a pick on its path can select
	the same candidate twice, and with the assembly's entry connection when
	any use of the assembly anchors on it. Each slots never fail (they skip
	consumed connections) but can take a connection from an explicit use that
	runs after them.
]]
local function markContested(g: graph)
	-- Connections consumed on arrival in an assembly's own scope (fb_anchor),
	-- over every way the assembly can be entered.
	local anchoredOn: { [number]: { [string]: boolean } } = {}
	for _, node in g.nodes do
		for _, edge in node.edges do
			if edge.anchor ~= nil then
				local set = anchoredOn[edge.node] or {}
				set[edge.anchor] = true
				anchoredOn[edge.node] = set
			end
		end
	end

	for id, node in g.nodes do
		if node.kind ~= "assembly" then
			continue
		end
		local sites: { site } = {}
		local visited: { [number]: boolean } = {}
		local function walk(nodeId: number, path: { { node: number, branch: number } })
			local current = g.nodes[nodeId]
			for branch, edge in current.edges do
				local step = table.clone(path)
				table.insert(step, { node = nodeId, branch = branch })
				if edge.connection ~= nil then
					table.insert(sites, { edge = edge, path = step, dynamic = current.kind == "each" })
				end
				local target = g.nodes[edge.node]
				if TRANSPARENT[target.kind] and not visited[edge.node] then
					visited[edge.node] = true
					walk(edge.node, step)
				end
			end
		end
		walk(id, {})

		local anchors = anchoredOn[id] or {}
		for i, a in sites do
			if not a.dynamic and repeats(g, a) then
				a.edge.contested = true
			end
			if not a.dynamic and a.edge.connection ~= nil and anchors[a.edge.connection] then
				a.edge.contested = true
			end
			for j, other in sites do
				if i == j or a.dynamic or a.edge.connection ~= other.edge.connection then
					continue
				end
				local conflicts = if other.dynamic then mayRunBefore(g, other, a) else not exclusive(g, a, other)
				if conflicts then
					a.edge.contested = true
				end
			end
		end
	end
end

-- Entry -------------------------------------------------------------------------

local function build(
	session: session,
	registry: registry,
	rootDefinition: definition,
	rootConfig: node_config
): outcome<graph>
	local b: builder = {
		session = session,
		registry = registry,
		spatial = spatial.newState(session),
		nodes = {},
		byKey = {},
		queue = {},
		counters = {},
		counterCount = 0,
	}

	local root = specialize(b, rootDefinition, rootConfig)
	if not root.ok then
		return root
	end

	local index = 1
	while index <= #b.queue do
		buildEdges(b, b.nodes[b.queue[index]])
		index += 1
	end

	local g: graph = {
		nodes = b.nodes,
		root = root.val,
		counters = b.counterCount,
	}
	checkScopes(b, g)
	markContested(g)
	return result.ok(g)
end

return table.freeze({
	build = build,
	ownConfig = ownConfig,
	referenceConfig = referenceConfig,
})
