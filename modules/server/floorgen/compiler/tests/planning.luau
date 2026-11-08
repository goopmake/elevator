--!strict
--[[
	Runs compiled floors through the real builder for the compiler's semantic
	tests, using the test-only box collision world (builder/tests/boxes).

	Planning errors (including detected compiler defects) raise, so a test
	fails loudly whenever the builder finds a broken compiler guarantee.
]]

local builder = require(script.Parent.Parent.Parent.builder)
local boxes = require(script.Parent.Parent.Parent.builder.tests.boxes)
local compiler = require(script.Parent.Parent)

export type volume = boxes.volume

export type options = {
	seed: number,
	maxRecursionDepth: number,
	origin: CFrame?,
	collides: boxes.predicate?,
}

export type plan = {
	status: "success",
	emissions: { builder.emission },
	volumes: { volume },
	-- Selected candidate indices of every pick execution, in order.
	selections: { { number } },
	counts: { number },
	plan: builder.plan,
}

local function run(floor: compiler.compiled_floor, options: options): plan
	local world = boxes.recorder(options.collides)
	local planned = builder.plan(floor, {
		seed = options.seed,
		maxRecursionDepth = options.maxRecursionDepth,
		origin = options.origin,
		collision = world.factory,
		trace = true,
	})
	if not planned.ok then
		error(string.format("planning failed: [%s] %s", planned.err.code, planned.err.message), 2)
	end
	local selections = {}
	local trace = planned.val.trace
	if trace then
		for _, pick in trace.picks do
			table.insert(selections, pick.chosen)
		end
	end
	return {
		status = "success",
		emissions = planned.val.emissions,
		volumes = world.volumes(),
		selections = selections,
		counts = planned.val.counters,
		plan = planned.val,
	}
end

return table.freeze({
	run = run,
	boxesOverlap = boxes.boxesOverlap,
})
