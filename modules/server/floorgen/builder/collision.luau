--!strict
--[[
	Default collision world: a private WorldModel.

	Accepted overlap volumes are private copies of each model entry's overlap
	part, placed at their planned frame inside a WorldModel that exists only
	for the duration of one planning run. A candidate volume is tested with
	WorldModel:GetPartsInPart, restricted to the accepted volumes, which is a
	full geometric test: rotation, unions and meshes follow their collision
	geometry, not their bounding boxes.

	Rolling back removes the most recently accepted volumes. Nothing is ever
	placed in Workspace, and the WorldModel is destroyed when planning ends.

	Touching is decided by the engine. To let rooms that share a wall sit
	flush, make overlap parts slightly smaller than the room shell.
]]

local compiler = require(script.Parent.Parent.compiler)
local types = require(script.Parent.types)

type collision_world = types.collision_world
type collision_context = types.collision_context

local function worldModel(context: collision_context): collision_world
	local world = Instance.new("WorldModel")
	world.Name = "FloorBuilderPlanning"
	local accepted = Instance.new("Folder")
	accepted.Name = "Accepted"
	accepted.Parent = world
	world.Parent = context.parent

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { accepted }
	params.MaxParts = 1

	local stack: { BasePart } = {}

	local function prepare(part: BasePart, cframe: CFrame)
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = true
		part.CFrame = cframe
	end

	local function tryAccept(entry: compiler.model_entry, cframe: CFrame): boolean
		local overlap = entry.overlap
		if overlap == nil then
			-- The compiler only marks models with an overlap volume conditional.
			return true
		end
		local probe = overlap.instantiate()
		prepare(probe, cframe)
		probe.Parent = world
		local hits = world:GetPartsInPart(probe, params)
		if #hits > 0 then
			probe:Destroy()
			return false
		end
		probe.Parent = accepted
		table.insert(stack, probe)
		return true
	end

	local function size(): number
		return #stack
	end

	local function truncate(keep: number)
		for i = #stack, keep + 1, -1 do
			stack[i]:Destroy()
			stack[i] = nil
		end
	end

	local function destroy()
		table.clear(stack)
		world:Destroy()
	end

	return table.freeze({
		tryAccept = tryAccept,
		size = size,
		truncate = truncate,
		destroy = destroy,
	})
end

return table.freeze({
	worldModel = worldModel,
})
