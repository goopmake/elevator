--!strict
--[[
	Commit: spawns a plan.

	Every decision was made during planning, so committing cannot fail. Each
	emission gets a fresh copy of its registry template, moved rigidly so that
	its PrimaryPart lands exactly on the planned pivot. Models are assembled
	in an unparented container that is parented once at the end.
]]

local types = require(script.Parent.types)

local function place(model: Model, pivot: CFrame)
	local primary = model.PrimaryPart
	if primary then
		-- Keep the model's own pivot offset relative to its PrimaryPart.
		model:PivotTo(pivot * primary.CFrame:ToObjectSpace(model:GetPivot()))
	else
		model:PivotTo(pivot)
	end
end

local function commit(plan: types.plan, parent: Instance?, name: string?): Model
	local container = Instance.new("Model")
	container.Name = name or "Floor"
	for _, emission in plan.emissions do
		local model = plan.floor.models[emission.model].instantiate()
		place(model, emission.pivot)
		model.Parent = container
	end
	container.Parent = parent
	return container
end

return table.freeze({
	commit = commit,
})
