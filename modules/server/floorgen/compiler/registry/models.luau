--!strict
--[[
	Model registry entries.

	An entry owns a private clone of a source Model, taken once at compile
	time. The source is never modified. The clone is only reachable through
	closures, so consumers cannot mutate the compiled template; they receive
	fresh copies from `instantiate`.

	The overlap part, when present, is detached from the template (it is never
	spawned) and kept as a separate private volume template.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = require(ReplicatedStorage.shared.modules.result)

local constants = require(script.Parent.Parent.constants)
local diagnostics = require(script.Parent.Parent.diagnostics)
local ir = require(script.Parent.Parent.ir)
local types = require(script.Parent.Parent.types)

type model_facts = ir.model_facts
type model_entry = types.model_entry
type overlap_volume = types.overlap_volume
type outcome<T> = diagnostics.outcome<T>

local errors = diagnostics.codes.errors

local NOT_ARCHIVABLE_HINT = "Make sure the Model, its PrimaryPart and its overlap part have Archivable enabled."

local function findOverlap(model: Model): { BasePart }
	local found = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name == constants.OVERLAP_PART_NAME then
			table.insert(found, descendant)
		end
	end
	return found
end

local function createEntry(id: number, facts: model_facts): outcome<model_entry>
	local source = facts.model
	-- Clone returns nil for a non-Archivable Model.
	local clone: Model? = source:Clone()
	if clone == nil then
		return diagnostics.fail(
			errors.MODEL_NOT_CLONEABLE,
			source,
			"The model could not be copied into the registry.",
			{ attribute = "Archivable", hint = NOT_ARCHIVABLE_HINT }
		)
	end

	local template: Model = clone
	local primaryPart = template.PrimaryPart
	if primaryPart == nil then
		template:Destroy()
		return diagnostics.fail(
			errors.MODEL_NOT_CLONEABLE,
			source,
			"The model's PrimaryPart was lost while copying it into the registry.",
			{ attribute = "Archivable", hint = NOT_ARCHIVABLE_HINT }
		)
	end

	local overlap: overlap_volume? = nil
	if facts.overlapCount == 1 and not facts.overlapIsPrimaryPart then
		local found = findOverlap(template)
		if #found ~= 1 then
			template:Destroy()
			return diagnostics.fail(
				errors.MODEL_NOT_CLONEABLE,
				source,
				"The overlap part was lost while copying the model into the registry.",
				{ attribute = "Archivable", hint = NOT_ARCHIVABLE_HINT }
			)
		end
		local volume = found[1]
		local offset = primaryPart.CFrame:ToObjectSpace(volume.CFrame)
		local size = volume.Size
		volume.Parent = nil
		overlap = table.freeze({
			offset = offset,
			size = size,
			instantiate = function(): BasePart
				return volume:Clone()
			end,
		})
	end

	return result.ok(table.freeze({
		id = id,
		name = source.Name,
		sourcePath = facts.path,
		connections = facts.connections,
		overlap = overlap,
		instantiate = function(): Model
			return template:Clone()
		end,
	}))
end

return table.freeze({
	createEntry = createEntry,
})
