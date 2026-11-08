--!strict
--[[
	Compiled representation construction.

	Converts the verified graph into the public, deeply frozen representation
	described in types.luau. Internal fields (source Instances, definitions,
	configurations) are dropped, so the result does not reference the source
	hierarchy.
]]

local constants = require(script.Parent.Parent.constants)
local ir = require(script.Parent.Parent.ir)
local registryModule = require(script.Parent.Parent.registry)
local types = require(script.Parent.Parent.types)

type graph = ir.graph
type edge_draft = ir.edge_draft
type registry = registryModule.registry

local function freezeEdge(edge: edge_draft): types.edge
	local e: types.edge = {
		node = edge.node,
		placement = edge.placement,
		recursive = edge.recursive,
		maxDepth = edge.maxDepth,
		optional = edge.optional,
		connection = edge.connection,
		anchor = edge.anchor,
		contested = edge.contested,
		mayFail = edge.mayFail,
		key = edge.key,
		source = edge.source,
	}
	return table.freeze(e)
end

local function freezeEdges(edges: { edge_draft }): { types.edge }
	local list: { types.edge } = table.create(#edges)
	for _, edge in edges do
		table.insert(list, freezeEdge(edge))
	end
	return table.freeze(list)
end

local function freezeNode(draft: ir.node_draft): types.node
	if draft.kind == "assembly" then
		local n: types.assembly_node = {
			kind = "assembly",
			id = draft.id,
			room = draft.room,
			children = freezeEdges(draft.edges),
			plugs = freezeEdges(draft.plugs),
			counter = draft.counter,
			maxCount = draft.config.maxCount,
			mayFail = draft.mayFail,
			source = draft.source,
		}
		return table.freeze(n)
	elseif draft.kind == "try" then
		local n: types.try_node = {
			kind = "try",
			id = draft.id,
			alternatives = freezeEdges(draft.edges),
			mayFail = draft.mayFail,
			source = draft.source,
		}
		return table.freeze(n)
	elseif draft.kind == "each" then
		local n: types.each_node = {
			kind = "each",
			id = draft.id,
			slots = freezeEdges(draft.edges),
			mayFail = draft.mayFail,
			source = draft.source,
		}
		return table.freeze(n)
	elseif draft.kind == "pick" then
		local candidates: { types.candidate } = table.create(#draft.edges)
		for _, edge in draft.edges do
			local c: types.candidate = { edge = freezeEdge(edge), weight = edge.weight }
			table.insert(candidates, table.freeze(c))
		end
		local n: types.pick_node = {
			kind = "pick",
			id = draft.id,
			amountMin = draft.config.pickMin or 0,
			amountMax = draft.config.pickMax or 0,
			unique = draft.config.pickUnique,
			mode = draft.config.pickMode,
			candidates = table.freeze(candidates),
			totalWeight = draft.totalWeight,
			mayFail = draft.mayFail,
			source = draft.source,
		}
		return table.freeze(n)
	else
		local n: types.model_node = {
			kind = "model",
			id = draft.id,
			model = draft.model or 0,
			conditional = draft.config.conditional,
			counter = draft.counter,
			maxCount = draft.config.maxCount,
			mayFail = draft.mayFail,
			source = draft.source,
		}
		return table.freeze(n)
	end
end

local function freeze(g: graph, registry: registry, warnings: { types.diagnostic }): types.compiled_floor
	local nodes: { types.node } = table.create(#g.nodes)
	for _, draft in g.nodes do
		table.insert(nodes, freezeNode(draft))
	end
	return table.freeze({
		formatVersion = constants.FORMAT_VERSION,
		root = g.root,
		nodes = table.freeze(nodes),
		models = table.freeze(table.clone(registry.entries)),
		counters = g.counters,
		warnings = table.freeze(table.clone(warnings)),
	})
end

return table.freeze({
	freeze = freeze,
})
