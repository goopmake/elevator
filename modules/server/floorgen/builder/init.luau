--!strict
--[[
	Floor builder: public API.

		local compiler = require(ServerStorage.modules.floorgen.compiler)
		local builder = require(ServerStorage.modules.floorgen.builder)

		local compiled = compiler.compile(source)
		if not compiled.ok then ... end

		local planned = builder.plan(compiled.val, { seed = 42 })
		if not planned.ok then
			warn(planned.err.code, planned.err.message)
			return
		end
		local floorModel = builder.commit(planned.val, workspace)

	plan() decides everything and spawns nothing. It only fails for invalid
	input, or if it detects that a compiler guarantee was violated; ordinary
	generation outcomes (overlaps, limits) are handled by the floor itself.
	commit() cannot fail and can be called any number of times per plan.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = require(ReplicatedStorage.shared.modules.result)

local compiler = require(script.Parent.compiler)
local commitModule = require(script.commit)
local options = require(script.options)
local planner = require(script.planner)
local stateModule = require(script.state)
local types = require(script.types)

export type builder_error = types.builder_error
export type error_code = types.error_code
export type options = types.options
export type plan = types.plan
export type emission = types.emission
export type stats = types.stats
export type trace = types.trace
export type failure_reason = types.failure_reason
export type collision_world = types.collision_world
export type collision_factory = types.collision_factory
export type collision_context = types.collision_context

export type plan_result = result.result<plan, builder_error>

local function plan(floor: compiler.compiled_floor, input: options): plan_result
	local checked = options.checkFloor(floor)
	if not checked.ok then
		return checked
	end
	local normalized = options.normalize(input)
	if not normalized.ok then
		return normalized
	end
	local settings = normalized.val

	local world = settings.collision({ parent = settings.planningParent })
	local s = stateModule.new(world, floor.counters)
	local outcome = planner.plan(floor, {
		maxRecursionDepth = settings.maxRecursionDepth,
		origin = settings.origin,
		seed = settings.seed,
		yieldBudget = settings.yieldBudget,
		trace = settings.trace,
	}, s)
	world.destroy()

	if outcome.defect then
		local e: builder_error = {
			code = "COMPILER_DEFECT",
			message = outcome.defect .. " Please report this together with the source hierarchy.",
		}
		return result.err(table.freeze(e))
	end

	local p: plan = {
		floor = floor,
		seed = settings.seed,
		origin = settings.origin,
		emissions = table.freeze(s.emissions),
		counters = table.freeze(s.counts),
		stats = table.freeze({
			executions = outcome.stats.executions,
			failures = table.freeze(outcome.stats.failures),
		}),
		trace = outcome.trace,
	}
	return result.ok(table.freeze(p))
end

local function commit(p: plan, parent: Instance?, name: string?): Model
	return commitModule.commit(p, parent, name)
end

-- Plans and commits in one step.
local function generate(floor: compiler.compiled_floor, input: options, parent: Instance?): result.result<Model, builder_error>
	local planned = plan(floor, input)
	if not planned.ok then
		return planned
	end
	return result.ok(commit(planned.val, parent))
end

export type builder = {
	plan: (floor: compiler.compiled_floor, options: options) -> plan_result,
	commit: (plan: plan, parent: Instance?, name: string?) -> Model,
	generate: (floor: compiler.compiled_floor, options: options, parent: Instance?) -> result.result<Model, builder_error>,
	DEFAULT_MAX_RECURSION_DEPTH: number,
}

local builder: builder = table.freeze({
	plan = plan,
	commit = commit,
	generate = generate,
	DEFAULT_MAX_RECURSION_DEPTH = options.DEFAULT_MAX_RECURSION_DEPTH,
})

return builder
