--!strict
--[[
	The private model registry.

	Every source Model reached during compilation is registered exactly once,
	no matter how many nodes or references use it. Registry ids are assigned in
	registration order, which follows the deterministic construction order, so
	equivalent inputs always produce the same ids.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = require(ReplicatedStorage.shared.modules.result)

local diagnostics = require(script.Parent.diagnostics)
local ir = require(script.Parent.ir)
local types = require(script.Parent.types)
local models = require(script.models)

type model_facts = ir.model_facts
type model_entry = types.model_entry
type outcome<T> = diagnostics.outcome<T>

export type registry = {
	entries: { model_entry },
	idOf: { [Model]: number },
	failed: { [Model]: boolean },
	-- Registry ids used by at least one conditional model node.
	usedConditionally: { [number]: boolean },
}

local function new(): registry
	return {
		entries = {},
		idOf = {},
		failed = {},
		usedConditionally = {},
	}
end

local function register(registry: registry, facts: model_facts): outcome<number>
	local existing = registry.idOf[facts.model]
	if existing then
		return result.ok(existing)
	end
	if registry.failed[facts.model] then
		-- Already reported.
		return result.err({})
	end

	local id = #registry.entries + 1
	local created = models.createEntry(id, facts)
	if not created.ok then
		registry.failed[facts.model] = true
		return created
	end
	table.insert(registry.entries, created.val)
	registry.idOf[facts.model] = id
	return result.ok(id)
end

local function markConditional(registry: registry, id: number)
	registry.usedConditionally[id] = true
end

return table.freeze({
	new = new,
	register = register,
	markConditional = markConditional,
})
