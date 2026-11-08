--!strict
--[[
	Planning: executes a compiled floor according to the execution contract
	in compiler/types.luau, without spawning anything.

	Expected failures (overlaps, counters, recursion limits, contested
	connections) are ordinary results that the graph handles. The planner also
	checks the compiler's guarantees as it goes; if one is ever violated
	(an edge marked as never failing fails, an uncontested connection is found
	consumed, a plug fails...), planning stops and reports a compiler defect
	instead of producing a floor from a broken graph.
]]

local compiler = require(script.Parent.Parent.compiler)
local types = require(script.Parent.types)
local stateModule = require(script.Parent.state)
local selection = require(script.Parent.selection)

type floor = compiler.compiled_floor
type node = compiler.node
type edge = compiler.edge
type state = stateModule.state
type failure_reason = types.failure_reason

export type settings = {
	maxRecursionDepth: number,
	origin: CFrame,
	seed: number,
	yieldBudget: number?,
	trace: boolean,
}

export type outcome = {
	-- Set when a compiler guarantee was violated.
	defect: string?,
	stats: types.stats,
	trace: types.trace?,
}

type run = {
	floor: floor,
	settings: settings,
	state: state,
	-- How many times each recursive edge is active on the current path.
	active: { [edge]: number },
	defect: string?,
	stats: types.stats,
	trace: types.trace?,
	lastYield: number,
}

local function fail(r: run, reason: failure_reason, nodeId: number, source: compiler.source_info?, pivot: CFrame)
	r.stats.failures[reason] = (r.stats.failures[reason] or 0) + 1
	if r.trace then
		table.insert(r.trace.failures, { reason = reason, node = nodeId, source = source, pivot = pivot })
	end
end

local function defect(r: run, message: string)
	if r.defect == nil then
		r.defect = message
	end
end

local function maybeYield(r: run)
	local budget = r.settings.yieldBudget
	if budget == nil then
		return
	end
	local now = os.clock()
	if now - r.lastYield >= budget then
		task.wait()
		r.lastYield = os.clock()
	end
end

local runNode: (r: run, n: node, pivot: CFrame, seed: number, depth: number, scope: number, anchor: string?) -> boolean

local function enter(r: run, e: edge, frame: CFrame, scope: number, seed: number, ordinal: number, depth: number): boolean
	local d = depth
	if e.recursive then
		local limit = e.maxDepth
		if d >= r.settings.maxRecursionDepth or (limit ~= nil and (r.active[e] or 0) >= limit) then
			fail(r, "recursion", e.node, e.source, frame * e.placement)
			return false
		end
		d += 1
	end
	if e.connection ~= nil then
		if stateModule.isConsumed(r.state, scope, e.connection) then
			if not e.contested then
				defect(r, string.format("Connection '%s' was already used at %s, which the compiler marked as uncontested.", e.connection, e.source.path))
			end
			fail(r, "connection", e.node, e.source, frame * e.placement)
			return false
		end
		stateModule.consume(r.state, scope, e.connection)
	end

	r.active[e] = (r.active[e] or 0) + 1
	local ok = runNode(
		r,
		r.floor.nodes[e.node],
		frame * e.placement,
		compiler.stream.childSeed(seed, e.key, ordinal),
		d,
		scope,
		e.anchor
	)
	r.active[e] -= 1
	return ok
end

local function execute(r: run, e: edge, frame: CFrame, scope: number, seed: number, ordinal: number, depth: number): boolean
	if r.defect then
		return false
	end
	local ok: boolean
	if e.optional then
		local cp = stateModule.checkpoint(r.state)
		if not enter(r, e, frame, scope, seed, ordinal, depth) then
			stateModule.restore(r.state, cp)
		end
		ok = true
	else
		ok = enter(r, e, frame, scope, seed, ordinal, depth)
	end
	if not ok and not e.mayFail and r.defect == nil then
		defect(r, string.format("%s failed although the compiler marked it as never failing.", e.source.path))
	end
	return ok
end

local function runModel(r: run, n: compiler.model_node, pivot: CFrame): boolean
	if n.counter ~= nil and n.maxCount ~= nil and not stateModule.count(r.state, n.counter, n.maxCount) then
		fail(r, "count", n.id, nil, pivot)
		return false
	end
	if n.conditional then
		local entry = r.floor.models[n.model]
		local overlap = entry.overlap
		if overlap == nil then
			defect(r, string.format("Conditional model %s has no overlap volume.", n.source.path))
			return false
		end
		if not r.state.world.tryAccept(entry, pivot * overlap.offset) then
			fail(r, "overlap", n.id, nil, pivot)
			return false
		end
	end
	stateModule.emit(r.state, table.freeze({ model = n.model, pivot = pivot, node = n.id }))
	return true
end

local function runAssembly(
	r: run,
	n: compiler.assembly_node,
	pivot: CFrame,
	seed: number,
	depth: number,
	anchor: string?
): boolean
	local cp = stateModule.checkpoint(r.state)
	if n.counter ~= nil and n.maxCount ~= nil and not stateModule.count(r.state, n.counter, n.maxCount) then
		fail(r, "count", n.id, nil, pivot)
		return false
	end
	local scope = stateModule.newScope(r.state)
	if anchor ~= nil then
		stateModule.consume(r.state, scope, anchor)
	end
	for _, child in n.children do
		if not execute(r, child, pivot, scope, seed, 0, depth) then
			stateModule.restore(r.state, cp)
			return false
		end
	end
	for _, plug in n.plugs do
		local connection = plug.connection
		if connection ~= nil and not stateModule.isConsumed(r.state, scope, connection) then
			if not execute(r, plug, pivot, scope, seed, 0, depth) then
				defect(r, string.format("Plug %s failed.", plug.source.path))
				return false
			end
		end
	end
	return true
end

local function runTry(r: run, n: compiler.try_node, pivot: CFrame, seed: number, depth: number, scope: number): boolean
	for _, alternative in n.alternatives do
		local cp = stateModule.checkpoint(r.state)
		if execute(r, alternative, pivot, scope, seed, 0, depth) then
			return true
		end
		stateModule.restore(r.state, cp)
		if r.defect then
			return false
		end
	end
	return true
end

local function runEach(r: run, n: compiler.each_node, pivot: CFrame, seed: number, depth: number, scope: number): boolean
	local open: { edge } = {}
	for _, slot in n.slots do
		local connection = slot.connection
		if connection ~= nil and not stateModule.isConsumed(r.state, scope, connection) then
			table.insert(open, slot)
		end
	end
	for _, slot in open do
		if not execute(r, slot, pivot, scope, seed, 0, depth) then
			return false
		end
	end
	return true
end

local function runPick(r: run, n: compiler.pick_node, pivot: CFrame, seed: number, depth: number, scope: number): boolean
	local draw = selection.new(n, seed)
	local amount = draw.amount()
	local chosen: { number } = {}
	if r.trace then
		table.insert(r.trace.picks, { node = n.id, chosen = chosen })
	end

	if n.mode == "strict" then
		for _ = 1, amount do
			local index = draw.next()
			if index == nil then
				defect(r, string.format("Pick %s ran out of candidates.", n.source.path))
				return false
			end
			table.insert(chosen, index)
			if n.unique then
				draw.exclude(index)
			end
		end
		for ordinal, index in chosen do
			if not execute(r, n.candidates[index].edge, pivot, scope, seed, ordinal, depth) then
				return false
			end
		end
		return true
	end

	local successes = 0
	local attempts = 0
	while successes < amount do
		local index = draw.next()
		if index == nil then
			return false
		end
		attempts += 1
		local cp = stateModule.checkpoint(r.state)
		if execute(r, n.candidates[index].edge, pivot, scope, seed, attempts, depth) then
			successes += 1
			table.insert(chosen, index)
			if n.unique then
				draw.exclude(index)
			end
		else
			stateModule.restore(r.state, cp)
			if r.defect then
				return false
			end
			draw.exclude(index)
		end
	end
	return true
end

function runNode(r: run, n: node, pivot: CFrame, seed: number, depth: number, scope: number, anchor: string?): boolean
	if r.defect then
		return false
	end
	r.stats.executions += 1
	maybeYield(r)
	if n.kind == "model" then
		return runModel(r, n, pivot)
	elseif n.kind == "assembly" then
		return runAssembly(r, n, pivot, seed, depth, anchor)
	elseif n.kind == "try" then
		return runTry(r, n, pivot, seed, depth, scope)
	elseif n.kind == "each" then
		return runEach(r, n, pivot, seed, depth, scope)
	else
		return runPick(r, n, pivot, seed, depth, scope)
	end
end

-- Plans a floor into `s`. The returned outcome reports defects; expected
-- generation failures never escape the root.
local function plan(floor: floor, settings: settings, s: state): outcome
	local r: run = {
		floor = floor,
		settings = settings,
		state = s,
		active = {},
		defect = nil,
		stats = { executions = 0, failures = {} },
		trace = if settings.trace then { picks = {}, failures = {} } else nil,
		lastYield = os.clock(),
	}
	local ok = runNode(r, floor.nodes[floor.root], settings.origin, compiler.stream.rootSeed(settings.seed), 0, 0, nil)
	if not ok and r.defect == nil then
		defect(r, "The root assembly failed although the compiler proved it cannot.")
	end
	return { defect = r.defect, stats = r.stats, trace = r.trace }
end

return table.freeze({
	plan = plan,
})
