--!strict
--[[
	Reference target resolution.

	A reference is an ObjectValue whose Value is the final target. Supported
	targets are model declarations (exact class Model) and container nodes
	(asm / try / pick Configurations), wherever they live, including inside
	Folders. References to references are rejected: there are no chains.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = require(ReplicatedStorage.shared.modules.result)

local constants = require(script.Parent.Parent.constants)
local diagnostics = require(script.Parent.Parent.diagnostics)
local ir = require(script.Parent.Parent.ir)
local parser = require(script.Parent.Parent.parser)

type outcome<T> = diagnostics.outcome<T>
type reference_use = ir.reference_use

local errors = diagnostics.codes.errors

local VALUE = "Value"

-- Validates the Value of a reference and returns the target Instance.
local function resolveTarget(ref: reference_use): outcome<Instance>
	local target = ref.instance.Value
	if target == nil then
		return diagnostics.fail(
			errors.REFERENCE_EMPTY,
			ref.instance,
			"This reference has no target.",
			{ attribute = VALUE, hint = "Set the ObjectValue's Value to a model or node." }
		)
	end

	if target.ClassName == constants.CLASS.reference then
		return diagnostics.fail(
			errors.REFERENCE_CHAIN,
			ref.instance,
			string.format("This reference points at another reference (%s).", diagnostics.pathOf(target)),
			{ attribute = VALUE, hint = "Point the ObjectValue at the final node or model directly." }
		)
	end

	if target.ClassName == constants.CLASS.model then
		return result.ok(target)
	end

	if target.ClassName == constants.CLASS.container then
		local classified = parser.classify(target)
		if classified.ok and classified.val.kind == "container" then
			return result.ok(target)
		end
		return diagnostics.fail(
			errors.REFERENCE_TARGET_INVALID,
			ref.instance,
			string.format("The target Configuration '%s' is not an asm, try or pick node.", target.Name),
			{ attribute = VALUE, hint = "Rename the target with a node prefix, or point at a different Instance." }
		)
	end

	return diagnostics.fail(
		errors.REFERENCE_UNSUPPORTED_TARGET,
		ref.instance,
		string.format("References cannot target %s Instances (%s).", target.ClassName, diagnostics.pathOf(target)),
		{ attribute = VALUE, hint = "Target a Model or an asm/try/pick Configuration." }
	)
end

-- The target of an ObjectValue if it is a supported Instance, without
-- reporting anything. Used for lenient look-ups (see spatial room detection).
local function peekTarget(objectValue: ObjectValue): Instance?
	local target = objectValue.Value
	if target == nil then
		return nil
	end
	if target.ClassName == constants.CLASS.model or target.ClassName == constants.CLASS.container then
		return target
	end
	return nil
end

return table.freeze({
	resolveTarget = resolveTarget,
	peekTarget = peekTarget,
})
