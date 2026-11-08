--!strict
--[[
	Failure-path analysis.

	Runtime failures are ordinary outcomes. Their sources are:
		* a conditional model whose overlap volume collides
		* a counted node (fb_max_count) beyond its count
		* a recursive edge entered beyond a recursion limit
		* a contested edge whose connection was already consumed
	They propagate upwards through edges, assemblies (which discard their own
	planned output), each nodes and picks (from candidates that can actually
	be selected). They are handled by try nodes and by optional edges.

	`mayFail` is the least fixed point of these rules over the (possibly
	cyclic) graph and over-approximates every real failure. The root must not
	be able to fail; otherwise every escaping failure source is reported
	together with the path along which it escapes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = require(ReplicatedStorage.shared.modules.result)

local diagnostics = require(script.Parent.Parent.diagnostics)
local ir = require(script.Parent.Parent.ir)

type graph = ir.graph
type node_draft = ir.node_draft
type edge_draft = ir.edge_draft
type diagnostic = diagnostics.diagnostic
type outcome<T> = diagnostics.outcome<T>

local errors = diagnostics.codes.errors

local function isSelectable(node: node_draft, edge: edge_draft): boolean
	return node.kind ~= "pick" or ((node.config.pickMax or 0) > 0 and edge.weight > 0)
end

-- Whether entering an edge can fail, given the current node values.
local function edgeFails(g: graph, edge: edge_draft): boolean
	return not edge.optional and (edge.recursive or edge.contested or g.nodes[edge.node].mayFail)
end

-- Whether a node can fail by itself (before looking at its children).
local function isSource(node: node_draft): boolean
	if node.kind == "model" then
		return node.config.conditional or node.config.maxCount ~= nil
	elseif node.kind == "assembly" then
		return node.config.maxCount ~= nil
	end
	return false
end

-- One application of the propagation rules to a node.
local function evaluate(g: graph, node: node_draft): boolean
	for _, edge in node.edges do
		edge.mayFail = edgeFails(g, edge)
	end
	for _, edge in node.plugs do
		edge.mayFail = edgeFails(g, edge)
	end
	if node.kind == "try" then
		return false
	end
	if isSource(node) then
		return true
	end
	for _, edge in node.edges do
		if edge.mayFail and isSelectable(node, edge) then
			return true
		end
	end
	return false
end

-- Computes mayFail for every node and edge (least fixed point).
local function analyse(g: graph)
	for _, node in g.nodes do
		node.mayFail = false
	end
	local changed = true
	while changed do
		changed = false
		for _, node in g.nodes do
			local value = evaluate(g, node)
			if value ~= node.mayFail then
				node.mayFail = value
				changed = true
			end
		end
	end
	-- Edges must reflect the final node values.
	for _, node in g.nodes do
		evaluate(g, node)
	end
end

local HINT = "Mark it (or an enclosing child) fb_optional, or wrap it in a 'try <label>' node."

-- Reports every failure source whose failure can reach the root.
local function unhandled(g: graph): { diagnostic }
	local found: { diagnostic } = {}
	local visited: { [number]: boolean } = {}
	local reportedEdges: { [edge_draft]: boolean } = {}

	local function report(instance: Instance, what: string, path: { string })
		table.insert(
			found,
			diagnostics.makeError(
				errors.FAILURE_UNHANDLED,
				instance,
				string.format("%s, and nothing handles that failure. Path: %s", what, table.concat(path, " > ")),
				{ hint = HINT }
			)
		)
	end

	local function visit(id: number, path: { string })
		if visited[id] then
			return
		end
		visited[id] = true
		local node = g.nodes[id]
		if node.kind == "try" then
			return -- handled here
		end
		local instance = node.definition.instance
		if node.kind == "model" and node.config.conditional then
			report(instance, "This conditional model can fail to emit when it overlaps another conditional model", path)
		end
		if node.config.maxCount ~= nil then
			report(
				instance,
				string.format("This node fails once it has been emitted %d time(s) (fb_max_count)", node.config.maxCount or 0),
				path
			)
		end
		for _, edge in node.edges do
			if not edge.mayFail or not isSelectable(node, edge) then
				continue
			end
			local childPath = table.clone(path)
			table.insert(childPath, edge.instance.Name)
			if not reportedEdges[edge] then
				if edge.recursive then
					reportedEdges[edge] = true
					report(edge.instance, "This recursive reference fails when a recursion limit is reached", childPath)
				elseif edge.contested then
					reportedEdges[edge] = true
					report(
						edge.instance,
						string.format("Connection '%s' may already be in use when this runs", edge.connection or "?"),
						childPath
					)
				end
			end
			visit(edge.node, childPath)
		end
	end

	local root = g.nodes[g.root]
	visit(g.root, { root.definition.instance.Name })
	return found
end

-- Runs the analysis and proves that the root cannot fail.
local function check(g: graph): outcome<nil>
	analyse(g)
	if not g.nodes[g.root].mayFail then
		return result.ok(nil)
	end
	local found = unhandled(g)
	if #found == 0 then
		return diagnostics.fail(
			errors.INTERNAL_INVARIANT,
			nil,
			"Failure analysis marked the root as failing but found no failure source."
		)
	end
	return result.err(found)
end

return table.freeze({
	analyse = analyse,
	check = check,
	isSelectable = isSelectable,
	edgeFails = edgeFails,
	isSource = isSource,
})
