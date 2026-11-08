--!strict
--[[
	Structural rules that relate a node to its parent, its children or its
	position in the graph.

	Each function checks one rule and returns the shared Result type; callers
	accumulate the errors.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = require(ReplicatedStorage.shared.modules.result)

local constants = require(script.Parent.Parent.constants)
local diagnostics = require(script.Parent.Parent.diagnostics)
local ir = require(script.Parent.Parent.ir)
local spatial = require(script.Parent.spatial)

type node_kind = ir.node_kind
type node_config = ir.node_config
type outcome<T> = diagnostics.outcome<T>

local errors = diagnostics.codes.errors

-- Only assemblies and models (inline or referenced) may be pick candidates.
local function checkPickCandidate(targetKind: node_kind, owner: Instance): outcome<nil>
	if targetKind == "assembly" or targetKind == "model" then
		return result.ok(nil)
	end
	return diagnostics.fail(
		errors.PICK_CHILD_NOT_ASSEMBLY,
		owner,
		string.format("Pick nodes may only contain assemblies and models, but this is a %s.", targetKind),
		{ hint = "Wrap it in an 'asm <label>' Configuration." }
	)
end

-- A plug must be a direct child of an assembly that has a room.
local function checkPlugPosition(config: node_config, parentKind: node_kind, hasRoom: boolean, owner: Instance): outcome<nil>
	if not config.plug then
		return result.ok(nil)
	end
	if parentKind ~= "assembly" then
		return diagnostics.fail(
			errors.PLUG_NOT_DIRECT_CHILD,
			owner,
			string.format("A plug (fb_plug) must be a direct child of an assembly, not of a %s node.", parentKind),
			{ attribute = constants.TAG.plug }
		)
	end
	if not hasRoom then
		return diagnostics.fail(
			errors.PLUG_INVALID,
			owner,
			"A plug seals connections of its assembly's room, but this assembly has no room.",
			{ attribute = constants.TAG.plug, hint = "Tag the assembly's room model fb_room." }
		)
	end
	return result.ok(nil)
end

-- A room must be a direct child of the assembly it belongs to.
local function checkRoomPosition(config: node_config, parentKind: node_kind, owner: Instance): outcome<nil>
	if not config.room or parentKind == "assembly" then
		return result.ok(nil)
	end
	return diagnostics.fail(
		errors.ROOM_NOT_DIRECT_CHILD,
		owner,
		string.format("A room (fb_room) must be a direct child of an assembly, not of a %s node.", parentKind),
		{
			attribute = constants.TAG.room,
			hint = "Move the room directly into its assembly, or remove the tag (override it on references).",
		}
	)
end

local function checkRoomUnique(room: spatial.room_lookup, assembly: Instance): outcome<nil>
	if room.kind ~= "ambiguous" then
		return result.ok(nil)
	end
	local paths = {}
	for _, instance in room.instances do
		table.insert(paths, diagnostics.pathOf(instance))
	end
	return diagnostics.fail(
		errors.ROOM_DUPLICATE,
		assembly,
		"An assembly can have only one room, found: " .. table.concat(paths, ", ") .. ".",
		{ attribute = constants.TAG.room }
	)
end

-- Rejects pick configurations whose selection can never be made.
local function checkPickSelection(
	owner: Instance,
	amountMax: number,
	unique: boolean,
	weights: { number }
): outcome<number>
	local total = 0
	local selectable = 0
	for _, weight in weights do
		total += weight
		if weight > 0 then
			selectable += 1
		end
	end

	if total > constants.MAX_EXACT_INTEGER then
		return diagnostics.fail(
			errors.PICK_WEIGHT_OVERFLOW,
			owner,
			"The sum of the candidates' fb_pick_weight values exceeds 2^53.",
			{ attribute = constants.ATTRIBUTE.pickWeight, hint = "Scale the weights down." }
		)
	end

	if amountMax > 0 and selectable == 0 then
		return diagnostics.fail(
			errors.PICK_IMPOSSIBLE,
			owner,
			string.format(
				"fb_pick_amount can be %d but no candidate can be selected (all weights are 0 or there are no candidates).",
				amountMax
			),
			{
				attribute = constants.ATTRIBUTE.pickAmount,
				hint = "Add candidates with a positive fb_pick_weight, or set fb_pick_amount to 0.",
			}
		)
	end

	if unique and amountMax > selectable then
		return diagnostics.fail(
			errors.PICK_IMPOSSIBLE,
			owner,
			string.format(
				"fb_pick_unique is set and fb_pick_amount can be %d, but only %d candidate(s) can be selected.",
				amountMax,
				selectable
			),
			{
				attribute = constants.ATTRIBUTE.pickAmount,
				hint = "Lower fb_pick_amount, add candidates, give zero-weight candidates a weight, or disable fb_pick_unique.",
			}
		)
	end

	return result.ok(total)
end

return table.freeze({
	checkPickCandidate = checkPickCandidate,
	checkRoomPosition = checkRoomPosition,
	checkPlugPosition = checkPlugPosition,
	checkRoomUnique = checkRoomUnique,
	checkPickSelection = checkPickSelection,
})
