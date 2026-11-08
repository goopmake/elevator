--!strict
--[[
	Validation of builder input: options and the compiled floor.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local result = require(ReplicatedStorage.shared.modules.result)

local compiler = require(script.Parent.Parent.compiler)
local collision = require(script.Parent.collision)
local types = require(script.Parent.types)

type builder_error = types.builder_error

export type normalized = {
	seed: number,
	maxRecursionDepth: number,
	origin: CFrame,
	collision: types.collision_factory,
	planningParent: Instance,
	yieldBudget: number?,
	trace: boolean,
}

local DEFAULT_MAX_RECURSION_DEPTH = 8

local function invalid(message: string): result.err<builder_error>
	local e: builder_error = { code = "OPTIONS_INVALID", message = message }
	return result.err(table.freeze(e))
end

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function isWhole(value: number): boolean
	return isFinite(value) and math.floor(value) == value
end

-- Options are statically typed, but callers may be untyped scripts, so every
-- field is checked at runtime as well.
local function normalize(options: types.options): result.result<normalized, builder_error>
	if type(options) ~= "table" then
		return invalid(string.format("options must be a table, got %s.", typeof(options)))
	end

	local seed: unknown = options.seed
	if type(seed) ~= "number" or not isFinite(seed) then
		return invalid("options.seed must be a finite number.")
	end

	local depth: unknown = options.maxRecursionDepth
	if depth == nil then
		depth = DEFAULT_MAX_RECURSION_DEPTH
	end
	if type(depth) ~= "number" or not isWhole(depth) or depth < 0 then
		return invalid("options.maxRecursionDepth must be a whole number >= 0.")
	end

	local origin: unknown = options.origin
	if origin == nil then
		origin = CFrame.identity
	end
	if typeof(origin) ~= "CFrame" then
		return invalid("options.origin must be a CFrame.")
	end

	local factory = options.collision
	if factory ~= nil and type(factory) ~= "function" then
		return invalid("options.collision must be a collision world factory function.")
	end

	local parent: unknown = options.planningParent
	if parent == nil then
		parent = ServerStorage
	end
	if typeof(parent) ~= "Instance" then
		return invalid("options.planningParent must be an Instance.")
	end

	local budget: unknown = options.yieldBudget
	if budget ~= nil and (type(budget) ~= "number" or not isFinite(budget) or budget <= 0) then
		return invalid("options.yieldBudget must be a positive number of seconds.")
	end

	local trace: unknown = options.trace
	if trace ~= nil and type(trace) ~= "boolean" then
		return invalid("options.trace must be a boolean.")
	end

	return result.ok({
		seed = seed,
		maxRecursionDepth = depth,
		origin = origin,
		collision = factory or collision.worldModel,
		planningParent = parent,
		yieldBudget = if type(budget) == "number" then budget else nil,
		trace = trace == true,
	})
end

-- Checks that a compiled floor is one this builder understands.
local function checkFloor(floor: compiler.compiled_floor): result.result<nil, builder_error>
	if type(floor) ~= "table" then
		local e: builder_error = {
			code = "FLOOR_INVALID",
			message = string.format("Expected a compiled floor, got %s.", typeof(floor)),
		}
		return result.err(table.freeze(e))
	end
	if floor.formatVersion ~= compiler.FORMAT_VERSION then
		local e: builder_error = {
			code = "FLOOR_INVALID",
			message = string.format(
				"The floor was compiled for format %s, but this builder expects format %d. Recompile it.",
				tostring(floor.formatVersion),
				compiler.FORMAT_VERSION
			),
		}
		return result.err(table.freeze(e))
	end
	if not table.isfrozen(floor) then
		local e: builder_error = {
			code = "FLOOR_INVALID",
			message = "The floor was not produced by the compiler (it is not frozen).",
		}
		return result.err(table.freeze(e))
	end
	return result.ok(nil)
end

return table.freeze({
	normalize = normalize,
	checkFloor = checkFloor,
	DEFAULT_MAX_RECURSION_DEPTH = DEFAULT_MAX_RECURSION_DEPTH,
})
