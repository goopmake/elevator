--!strict
--[[
	Change detection for live recompilation.

	Watches the opened root and every referenced definition outside it:
	structure (children added or removed), properties (names, ObjectValue
	targets, part CFrames), attributes and language tags. Any change calls
	`onChange`; the session debounces recompilation.

	The watched set depends on the last analysis (new references can pull in
	new definitions), so the session rebuilds the watcher after every
	analysis.
]]

local CollectionService = game:GetService("CollectionService")

local maidModule = require(script.Parent.maid)

export type maid = maidModule.maid

-- Properties the plugin itself changes for display (ghosting); reacting to
-- them would make live preview recompile in a loop.
local IGNORED_PROPERTIES: { [string]: boolean } = {
	LocalTransparencyModifier = true,
}

local function watch(subtrees: { Instance }, tags: { string }, onChange: () -> ()): maid
	local m = maidModule.new()
	local watched: { [Instance]: boolean } = {}

	local function onProperty(property: string)
		if not IGNORED_PROPERTIES[property] then
			onChange()
		end
	end

	local function watchInstance(instance: Instance)
		if watched[instance] then
			return
		end
		watched[instance] = true
		m:give(instance.Changed:Connect(onProperty))
		m:give(instance.AttributeChanged:Connect(onChange))
	end

	for _, subtree in subtrees do
		watchInstance(subtree)
		for _, descendant in subtree:GetDescendants() do
			watchInstance(descendant)
		end
		m:give(subtree.DescendantAdded:Connect(function(instance)
			watchInstance(instance)
			onChange()
		end))
		m:give(subtree.DescendantRemoving:Connect(function()
			onChange()
		end))
	end

	-- Tags have no per-Instance change event; listen per language tag and
	-- react when the tagged Instance is one we watch.
	for _, tag in tags do
		local function onTag(instance: Instance)
			if watched[instance] then
				onChange()
			end
		end
		m:give(CollectionService:GetInstanceAddedSignal(tag):Connect(onTag))
		m:give(CollectionService:GetInstanceRemovedSignal(tag):Connect(onTag))
	end

	return m
end

return table.freeze({
	watch = watch,
})
