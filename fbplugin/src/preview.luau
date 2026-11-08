--!strict
--[[
	Preview generation in edit mode.

	Plans the compiled floor with the project's own builder and commits it
	into a preview Model in Workspace. The preview is not Archivable, so it is
	never saved with the place, and its parts can be locked so clicks select
	the source instead.
]]

local result = require(script.Parent.result)
local engineModule = require(script.Parent.engine)
local engineTypes = require(script.Parent.engine_types)

export type options = {
	seed: number,
	maxDepth: number,
	offset: Vector3,
	lock: boolean,
	-- Tried in order; the first where collision queries work is used.
	planningParents: { Instance },
	parent: Instance,
}

export type preview = {
	model: Model,
	plan: engineTypes.plan,
	seed: number,
	origin: CFrame,
	-- Seconds spent planning and committing.
	planning: number,
	committing: number,
}

local PREVIEW_NAME = "FloorBuilderPreview"

-- Whether WorldModel spatial queries work under `parent`: two overlapping
-- parts must be reported. Checked once per parent, because a planning world
-- that silently finds no overlaps would produce wrong previews.
local verified: { [Instance]: boolean } = {}

local function collisionWorks(parent: Instance): boolean
	local known = verified[parent]
	if known ~= nil then
		return known
	end
	local world = Instance.new("WorldModel")
	world.Name = "FloorBuilderCollisionCheck"
	local a = Instance.new("Part")
	a.Anchored = true
	a.Size = Vector3.new(2, 2, 2)
	a.CFrame = CFrame.new(0, 1e4, 0)
	a.Parent = world
	local b = a:Clone()
	b.CFrame = CFrame.new(0.5, 1e4, 0)
	b.Parent = world
	world.Parent = parent
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { a }
	local ok, hits = pcall(function()
		return world:GetPartsInPart(b, params)
	end)
	world:Destroy()
	local works = ok and #hits == 1
	verified[parent] = works
	return works
end

-- The first parent among `candidates` where collision queries work.
local function planningParent(candidates: { Instance }): Instance?
	for _, candidate in candidates do
		if collisionWorks(candidate) then
			return candidate
		end
	end
	return nil
end

local function generate(
	engine: engineModule.engine,
	floor: engineTypes.compiled_floor,
	options: options
): result.result<preview, string>
	local origin = CFrame.new(options.offset)
	local planningAt = planningParent(options.planningParents)
	if planningAt == nil then
		return result.err("Collision queries do not work in this Studio session, so previews would be wrong.")
	end
	local started = os.clock()
	-- The builder is project code that may be mid-edit.
	local ok, planned = pcall(engine.builder.plan, floor, {
		seed = options.seed,
		maxRecursionDepth = options.maxDepth,
		origin = origin,
		planningParent = planningAt,
		trace = true,
	})
	if not ok then
		return result.err("The builder raised an error: " .. tostring(planned))
	end
	if not planned.ok then
		return result.err(string.format("[%s] %s", planned.err.code, planned.err.message))
	end
	local planning = os.clock() - started

	started = os.clock()
	local committed, model = pcall(engine.builder.commit, planned.val, nil, PREVIEW_NAME)
	if not committed then
		return result.err("Commit raised an error: " .. tostring(model))
	end
	model.Archivable = false
	model:SetAttribute("FloorBuilderSeed", options.seed)
	if options.lock then
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Locked = true
			end
		end
	end
	model.Parent = options.parent
	return result.ok({
		model = model,
		plan = planned.val,
		seed = options.seed,
		origin = origin,
		planning = planning,
		committing = os.clock() - started,
	})
end

local function destroy(p: preview)
	p.model:Destroy()
end

return table.freeze({
	generate = generate,
	destroy = destroy,
	PREVIEW_NAME = PREVIEW_NAME,
})
