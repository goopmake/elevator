--!strict
--[[
	Authoring helpers. Every action runs inside one ChangeHistoryService
	recording, so it is a single undo step, and is cancelled (rolled back by
	Studio) if it fails.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")

local result = require(script.Parent.result)
local engineTypes = require(script.Parent.engine_types)

export type context = {
	compiler: engineTypes.compiler,
	root: Instance?,
	selection: { Instance },
}

export type container_kind = "assembly" | "try" | "pick" | "each"

local function isContainerKind(kind: engineTypes.outline_kind?): boolean
	return kind == "assembly" or kind == "try" or kind == "pick" or kind == "each"
end

local function record(name: string, body: () -> result.result<string, string>): result.result<string, string>
	local id = ChangeHistoryService:TryBeginRecording(name)
	if id == nil then
		return result.err("Studio is busy with another change; try again.")
	end
	local outcome = body()
	ChangeHistoryService:FinishRecording(
		id,
		if outcome.ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
	)
	return outcome
end

-- Where new nodes go: the selected container, the container of the selected
-- node, or the root.
local function targetContainer(ctx: context): Instance?
	local first = ctx.selection[1]
	if first then
		if isContainerKind(ctx.compiler.identify(first)) then
			return first
		end
		local parent = first.Parent
		if parent and isContainerKind(ctx.compiler.identify(parent)) then
			return parent
		end
	end
	return ctx.root
end

local function prefixFor(ctx: context, kind: container_kind): string
	local p = ctx.compiler.constants.PREFIX
	local prefix = if kind == "assembly" then p.assembly elseif kind == "try" then p.try elseif kind == "pick" then p.pick else p.each
	return prefix .. ctx.compiler.constants.PREFIX_SEPARATOR
end

local function addNode(ctx: context, kind: container_kind): result.result<string, string>
	local container = targetContainer(ctx)
	if container == nil then
		return result.err("Open a root or select a container first.")
	end
	return record("Floor builder: add " .. kind, function()
		local node = Instance.new("Configuration")
		node.Name = prefixFor(ctx, kind) .. "New"
		if kind == "pick" then
			node:SetAttribute(ctx.compiler.constants.ATTRIBUTE.pickAmount, 1)
		end
		node.Parent = container
		Selection:Set({ node })
		return result.ok(string.format("Added %s to %s.", node.Name, container.Name))
	end)
end

--[[
	Wraps the selected siblings in a new try node at the position of the first
	one. Children keep their authored order: siblings after the wrapped ones
	are re-appended after the new try node.
]]
local function wrapInTry(ctx: context): result.result<string, string>
	local selection = ctx.selection
	if #selection == 0 then
		return result.err("Select one or more nodes to wrap.")
	end
	local parent = selection[1].Parent
	if parent == nil or not isContainerKind(ctx.compiler.identify(parent)) then
		return result.err("The selection must be children of an asm/try/pick/each node.")
	end
	local selected: { [Instance]: boolean } = {}
	for _, instance in selection do
		if instance.Parent ~= parent then
			return result.err("All selected nodes must have the same parent.")
		end
		selected[instance] = true
	end
	return record("Floor builder: wrap in try", function()
		local siblings = parent:GetChildren()
		local wrapper = Instance.new("Configuration")
		wrapper.Name = prefixFor(ctx, "try") .. selection[1].Name
		wrapper.Parent = parent
		local seenSelected = false
		local after: { Instance } = {}
		for _, child in siblings do
			if selected[child] then
				seenSelected = true
				child.Parent = wrapper
			elseif seenSelected then
				table.insert(after, child)
			end
		end
		for _, child in after do
			child.Parent = nil
			child.Parent = parent
		end
		Selection:Set({ wrapper })
		return result.ok(string.format("Wrapped %d node(s) in %s.", #selection, wrapper.Name))
	end)
end

local function toggleTag(ctx: context, tag: string): result.result<string, string>
	if #ctx.selection == 0 then
		return result.err("Select the nodes to tag.")
	end
	for _, instance in ctx.selection do
		if ctx.compiler.identify(instance) == nil then
			return result.err(instance.Name .. " is a Folder; it cannot be tagged.")
		end
	end
	local adding = not ctx.selection[1]:HasTag(tag)
	return record("Floor builder: toggle " .. tag, function()
		for _, instance in ctx.selection do
			if adding then
				instance:AddTag(tag)
			else
				instance:RemoveTag(tag)
			end
		end
		return result.ok(string.format("%s %s on %d instance(s).", if adding then "Added" else "Removed", tag, #ctx.selection))
	end)
end

local function pasteReference(ctx: context, target: Instance): result.result<string, string>
	if target.Parent == nil then
		return result.err("The copied target no longer exists.")
	end
	local container = targetContainer(ctx)
	if container == nil then
		return result.err("Select a container for the reference.")
	end
	return record("Floor builder: add reference", function()
		local reference = Instance.new("ObjectValue")
		local label = ctx.compiler.identify(target)
		local name = target.Name
		if label ~= "model" then
			-- Drop the target's own prefix: "asm Hall" -> "Hall".
			local at = string.find(name, ctx.compiler.constants.PREFIX_SEPARATOR, 1, true)
			if at then
				name = string.sub(name, at + 1)
			end
		end
		reference.Name = ctx.compiler.constants.PREFIX.reference .. ctx.compiler.constants.PREFIX_SEPARATOR .. name
		reference.Value = target
		reference.Parent = container
		Selection:Set({ reference })
		return result.ok(string.format("Added %s in %s.", reference.Name, container.Name))
	end)
end

local function addConnection(ctx: context): result.result<string, string>
	local parts: { BasePart } = {}
	for _, instance in ctx.selection do
		if instance:IsA("BasePart") then
			table.insert(parts, instance)
		end
	end
	if #parts == 0 then
		return result.err("Select the part (inside a model) that should carry the connection.")
	end
	return record("Floor builder: add connection", function()
		local created: { Instance } = {}
		for _, part in parts do
			local attachment = Instance.new("Attachment")
			local index = 1
			while part:FindFirstChild("Door" .. index) do
				index += 1
			end
			attachment.Name = "Door" .. index
			attachment:AddTag(ctx.compiler.constants.TAG.connection)
			attachment.Parent = part
			table.insert(created, attachment)
		end
		Selection:Set(created)
		return result.ok("Added connection(s). Rotate them so their front (LookVector) points out of the room.")
	end)
end

local OVERLAP_INSET = 0.1

local function addOverlap(ctx: context): result.result<string, string>
	local models: { Model } = {}
	for _, instance in ctx.selection do
		if instance:IsA("Model") then
			table.insert(models, instance)
		end
	end
	if #models == 0 then
		return result.err("Select the model(s) that need an overlap volume.")
	end
	local name = ctx.compiler.constants.OVERLAP_PART_NAME
	for _, model in models do
		if model:FindFirstChild(name, true) then
			return result.err(model.Name .. " already has an overlap part.")
		end
	end
	return record("Floor builder: add overlap volume", function()
		for _, model in models do
			local cframe, size = model:GetBoundingBox()
			local part = Instance.new("Part")
			part.Name = name
			part.Anchored = true
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			part.Transparency = 1
			part.CFrame = cframe
			part.Size = Vector3.new(
				math.max(0.05, size.X - 2 * OVERLAP_INSET),
				math.max(0.05, size.Y - 2 * OVERLAP_INSET),
				math.max(0.05, size.Z - 2 * OVERLAP_INSET)
			)
			part.Parent = model
		end
		return result.ok(string.format("Added overlap volume(s), %.2f studs inside the bounding box.", OVERLAP_INSET))
	end)
end

return table.freeze({
	addNode = addNode,
	wrapInTry = wrapInTry,
	toggleTag = toggleTag,
	pasteReference = pasteReference,
	addConnection = addConnection,
	addOverlap = addOverlap,
	targetContainer = targetContainer,
})
