--!strict
--[[
	Final invariant verification.

	Re-checks, independently of the stages that established them, every
	invariant the runtime builder relies on. A violation here is a compiler
	defect, not a source error, and is reported as INTERNAL_INVARIANT so that
	a broken graph can never be returned as executable.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = require(ReplicatedStorage.shared.modules.result)

local constants = require(script.Parent.Parent.constants)
local diagnostics = require(script.Parent.Parent.diagnostics)
local ir = require(script.Parent.Parent.ir)
local registryModule = require(script.Parent.Parent.registry)
local failurePaths = require(script.Parent.Parent.validation.failure_paths)

type graph = ir.graph
type node_draft = ir.node_draft
type edge_draft = ir.edge_draft
type diagnostic = diagnostics.diagnostic
type outcome<T> = diagnostics.outcome<T>
type registry = registryModule.registry

local errors = diagnostics.codes.errors

local function isNatural(value: number?): boolean
	return value ~= nil
		and value == value
		and value >= 0
		and value <= constants.MAX_EXACT_INTEGER
		and math.floor(value) == value
end

-- Every cycle must contain a recursive edge: the graph restricted to
-- non-recursive edges must be acyclic.
local function boundedRecursion(g: graph): boolean
	local state: { number } = table.create(#g.nodes, 0) -- 0 new, 1 active, 2 done
	type frame = { node: number, edge: number }
	for start = 1, #g.nodes do
		if state[start] ~= 0 then
			continue
		end
		local work: { frame } = { { node = start, edge = 1 } }
		state[start] = 1
		while #work > 0 do
			local top = work[#work]
			local edges = g.nodes[top.node].edges
			if top.edge > #edges then
				state[top.node] = 2
				table.remove(work)
				continue
			end
			local edge = edges[top.edge]
			top.edge += 1
			if not edge.recursive then
				if state[edge.node] == 1 then
					return false
				elseif state[edge.node] == 0 then
					state[edge.node] = 1
					table.insert(work, { node = edge.node, edge = 1 })
				end
			end
		end
	end
	return true
end

local function verify(g: graph, registry: registry): outcome<nil>
	local problems: { diagnostic } = {}
	local function violated(message: string)
		table.insert(problems, diagnostics.makeError(errors.INTERNAL_INVARIANT, nil, message))
	end

	local count = #g.nodes
	local root = g.nodes[g.root]
	if root == nil then
		violated("The root node does not exist.")
		return result.err(problems)
	end
	if root.kind ~= "assembly" then
		violated("The root node is not an assembly.")
	end
	if root.mayFail then
		violated("The root assembly may fail.")
	end
	if root.counter ~= nil then
		violated("The root assembly is counted.")
	end

	local function checkEdge(id: number, edge: edge_draft): boolean
		if edge.node < 1 or edge.node > count then
			violated(string.format("Node %d has an edge to missing node %d.", id, edge.node))
			return false
		end
		if edge.recursive and not edge.isReference then
			violated(string.format("Node %d has a recursive edge that is not a reference.", id))
		end
		if edge.contested and edge.connection == nil then
			violated(string.format("Node %d has a contested edge without a connection.", id))
		end
		if edge.maxDepth ~= nil and not isNatural(edge.maxDepth) then
			violated(string.format("Node %d has an edge with an invalid maxDepth.", id))
		end
		if edge.mayFail ~= failurePaths.edgeFails(g, edge) then
			violated(string.format("Node %d has an edge with inconsistent mayFail.", id))
		end
		if edge.key ~= math.floor(edge.key) or edge.key < 0 or edge.key >= 2 ^ 32 then
			violated(string.format("Node %d has an edge with an invalid stream key.", id))
		end
		return true
	end

	for id, node in g.nodes do
		if node.id ~= id then
			violated(string.format("Node %d has mismatched id %d.", id, node.id))
		end
		for _, edge in node.edges do
			if not checkEdge(id, edge) then
				return result.err(problems)
			end
		end
		for _, plug in node.plugs do
			if not checkEdge(id, plug) then
				return result.err(problems)
			end
			local target = g.nodes[plug.node]
			if node.kind ~= "assembly" or target.kind ~= "model" or plug.connection == nil then
				violated(string.format("Node %d has a malformed plug.", id))
			end
			if plug.mayFail or plug.recursive or target.mayFail then
				violated(string.format("Node %d has a plug that may fail.", id))
			end
		end

		local expected = false
		if node.kind ~= "try" then
			expected = failurePaths.isSource(node)
			for _, edge in node.edges do
				if edge.mayFail and failurePaths.isSelectable(node, edge) then
					expected = true
				end
			end
		end
		if node.mayFail ~= expected then
			violated(string.format("Node %d has inconsistent mayFail.", id))
		end

		if node.counter ~= nil then
			if node.counter < 1 or node.counter > g.counters or not isNatural(node.config.maxCount) then
				violated(string.format("Node %d has an invalid counter.", id))
			end
		elseif node.config.maxCount ~= nil then
			violated(string.format("Node %d has fb_max_count but no counter.", id))
		end

		if node.kind == "model" then
			local entry = if node.model then registry.entries[node.model] else nil
			if entry == nil then
				violated(string.format("Model node %d has no registry entry.", id))
			elseif node.config.conditional and entry.overlap == nil then
				violated(string.format("Conditional model node %d has no overlap volume.", id))
			end
			if #node.edges > 0 or #node.plugs > 0 then
				violated(string.format("Model node %d has children.", id))
			end
		elseif node.kind == "assembly" then
			if node.room ~= nil and registry.entries[node.room] == nil then
				violated(string.format("Assembly node %d has a missing room entry.", id))
			end
		elseif node.kind == "each" then
			for _, edge in node.edges do
				if edge.connection == nil or edge.node ~= node.edges[1].node then
					violated(string.format("Each node %d has a malformed slot.", id))
				end
			end
		elseif node.kind == "pick" then
			local low, high = node.config.pickMin, node.config.pickMax
			if not isNatural(low) or not isNatural(high) or (low or 0) > (high or 0) then
				violated(string.format("Pick node %d has an invalid amount.", id))
			else
				local total, selectable = 0, 0
				for _, edge in node.edges do
					local kind = g.nodes[edge.node].kind
					if kind ~= "assembly" and kind ~= "model" then
						violated(string.format("Pick node %d has an invalid candidate.", id))
					end
					if not isNatural(edge.weight) then
						violated(string.format("Pick node %d has an invalid weight.", id))
					end
					total += edge.weight
					if edge.weight > 0 then
						selectable += 1
					end
				end
				local amountMax = high or 0
				if total ~= node.totalWeight or total > constants.MAX_EXACT_INTEGER then
					violated(string.format("Pick node %d has an inconsistent total weight.", id))
				end
				if amountMax > 0 and selectable == 0 then
					violated(string.format("Pick node %d can never select a candidate.", id))
				end
				if node.config.pickUnique and amountMax > selectable then
					violated(string.format("Pick node %d cannot make a unique selection.", id))
				end
			end
		end
	end

	if not boundedRecursion(g) then
		violated("The graph contains a cycle without a recursive edge.")
	end

	if #problems > 0 then
		return result.err(problems)
	end
	return result.ok(nil)
end

return table.freeze({
	verify = verify,
})
