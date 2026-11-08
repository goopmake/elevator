--!strict
--[[
	Recursive graph construction.

	Recursion is a language feature: references may form direct, indirect or
	mutual cycles. The graph keeps those cycles (nothing is inlined). To make
	execution terminate, every reference edge that lies on a cycle is marked
	`recursive`; entering such an edge consumes one level of the builder's
	recursion budget and fails once the budget is exhausted.

	An edge lies on a cycle exactly when its source and target are in the same
	strongly connected component. Inline edges follow the acyclic source
	hierarchy, so every cycle contains at least one reference edge and is
	therefore bounded. compilation/verify re-checks this independently.
]]

local ir = require(script.Parent.Parent.ir)

type graph = ir.graph

-- Iterative Tarjan. Returns the component index of every node.
local function components(g: graph): { number }
	local count = #g.nodes
	local index: { number } = table.create(count, 0)
	local low: { number } = table.create(count, 0)
	local onStack: { boolean } = table.create(count, false)
	local component: { number } = table.create(count, 0)
	local stack: { number } = {}
	local nextIndex = 1
	local nextComponent = 1

	type frame = { node: number, edge: number }

	for start = 1, count do
		if index[start] ~= 0 then
			continue
		end
		local work: { frame } = { { node = start, edge = 1 } }
		index[start] = nextIndex
		low[start] = nextIndex
		nextIndex += 1
		table.insert(stack, start)
		onStack[start] = true

		while #work > 0 do
			local top = work[#work]
			local v = top.node
			local edges = g.nodes[v].edges
			if top.edge <= #edges then
				local w = edges[top.edge].node
				top.edge += 1
				if index[w] == 0 then
					index[w] = nextIndex
					low[w] = nextIndex
					nextIndex += 1
					table.insert(stack, w)
					onStack[w] = true
					table.insert(work, { node = w, edge = 1 })
				elseif onStack[w] then
					low[v] = math.min(low[v], index[w])
				end
			else
				table.remove(work)
				if #work > 0 then
					local parent = work[#work].node
					low[parent] = math.min(low[parent], low[v])
				end
				if low[v] == index[v] then
					while true do
						local w = stack[#stack]
						stack[#stack] = nil
						onStack[w] = false
						component[w] = nextComponent
						if w == v then
							break
						end
					end
					nextComponent += 1
				end
			end
		end
	end

	return component
end

local function markRecursiveEdges(g: graph)
	local component = components(g)
	for _, node in g.nodes do
		for _, edge in node.edges do
			edge.recursive = edge.isReference and component[node.id] == component[edge.node]
		end
	end
end

return table.freeze({
	markRecursiveEdges = markRecursiveEdges,
})
