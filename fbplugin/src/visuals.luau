--!strict
--[[
	In-world visualisations, drawn with adornments in CoreGui so nothing is
	added to the place or its undo history.

		connections  cone per fb_connection Attachment, pointing out of the room
		             (its LookVector), with its name
		overlaps     translucent box on every overlap part of the source models
		problems     outline around models with errors (red) or warnings (orange)
		selection    outline around the selected node's models
		failures     marker where the last preview had a handled failure
]]

local Workspace = game:GetService("Workspace")

local engineTypes = require(script.Parent.engine_types)
local theme = require(script.Parent.ui.theme)

type outline_node = engineTypes.outline_node

export type input = {
	analysis: engineTypes.analysis?,
	models: { Model },
	selected: Instance?,
	failures: { engineTypes.trace_failure },
	constants: engineTypes.constants?,
	show: {
		connections: boolean,
		overlaps: boolean,
		problems: boolean,
		failures: boolean,
	},
}

export type visuals = {
	update: (input: input) -> (),
	destroy: () -> (),
}

local MAX_ITEMS = 400

local function label(parent: Instance, adornee: Instance, text: string, color: Color3, worldOffset: Vector3?)
	local gui = Instance.new("BillboardGui")
	gui.Adornee = adornee
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(160, 16)
	gui.StudsOffset = Vector3.new(0, 1.2, 0)
	if worldOffset then
		gui.StudsOffsetWorldSpace = worldOffset
	end
	gui.LightInfluence = 0
	local text_ = Instance.new("TextLabel")
	text_.BackgroundTransparency = 1
	text_.Size = UDim2.fromScale(1, 1)
	text_.Font = Enum.Font.Code
	text_.TextSize = 12
	text_.TextColor3 = color
	text_.TextStrokeTransparency = 0.4
	text_.Text = text
	text_.Parent = gui
	gui.Parent = parent
end

local function outlineBox(parent: Instance, adornee: PVInstance, color: Color3, thickness: number)
	local box = Instance.new("SelectionBox")
	box.Adornee = adornee
	box.Color3 = color
	box.LineThickness = thickness
	box.SurfaceTransparency = 1
	box.Parent = parent
end

local function new(parent: Instance): visuals
	local folder = Instance.new("Folder")
	folder.Name = "FloorBuilderVisuals"
	folder.Archivable = false
	folder.Parent = parent

	local function update(input: input)
		folder:ClearAllChildren()
		local count = 0
		local function budget(): boolean
			count += 1
			return count <= MAX_ITEMS
		end

		local constants = input.constants
		if constants then
			for _, model in input.models do
				if not model.Parent then
					continue
				end
				for _, descendant in model:GetDescendants() do
					if
						input.show.connections
						and descendant:IsA("Attachment")
						and descendant:HasTag(constants.TAG.connection)
						and budget()
					then
						local part = descendant.Parent
						if part and part:IsA("BasePart") then
							local cone = Instance.new("ConeHandleAdornment")
							cone.Adornee = part
							cone.CFrame = descendant.CFrame
							cone.Height = 1.6
							cone.Radius = 0.35
							cone.AlwaysOnTop = true
							cone.ZIndex = 1
							cone.Color3 = theme.visual.connection
							cone.Parent = folder
							label(folder, descendant, descendant.Name, theme.visual.connection, nil)
						end
					elseif
						input.show.overlaps
						and descendant:IsA("BasePart")
						and descendant.Name == constants.OVERLAP_PART_NAME
						and budget()
					then
						local box = Instance.new("BoxHandleAdornment")
						box.Adornee = descendant
						box.Size = descendant.Size
						box.Color3 = theme.visual.overlap
						box.Transparency = 0.75
						box.AlwaysOnTop = false
						box.ZIndex = 0
						box.Parent = folder
					end
				end
			end
		end

		local a = input.analysis
		if input.show.problems and a then
			local function visit(node: outline_node)
				local instance = node.instance
				if #node.diagnostics > 0 and instance:IsA("PVInstance") and budget() then
					local hasError = false
					for _, d in node.diagnostics do
						if d.severity == "error" then
							hasError = true
						end
					end
					outlineBox(folder, instance, if hasError then theme.visual.error else theme.visual.warning, 0.08)
				end
				for _, child in node.children do
					visit(child)
				end
			end
			if a.root then
				visit(a.root)
			end
			for _, def in a.definitions do
				visit(def)
			end
		end

		local selected = input.selected
		if selected and selected.Parent then
			if selected:IsA("PVInstance") then
				outlineBox(folder, selected, theme.visual.selection, 0.12)
			else
				-- A container: outline the models inside it.
				for _, descendant in selected:GetDescendants() do
					if descendant:IsA("Model") and budget() then
						outlineBox(folder, descendant, theme.visual.selection, 0.06)
					end
				end
			end
		end

		if input.show.failures then
			local terrain = Workspace.Terrain
			for _, failure in input.failures do
				if not budget() then
					break
				end
				local marker = Instance.new("SphereHandleAdornment")
				marker.Adornee = terrain
				marker.CFrame = failure.pivot
				marker.Radius = 0.6
				marker.AlwaysOnTop = true
				marker.ZIndex = 2
				marker.Color3 = theme.visual.failure
				marker.Parent = folder
				local source = failure.source
				local text = failure.reason .. (if source then ": " .. source.label else "")
				label(folder, terrain, text, theme.visual.failure, failure.pivot.Position)
			end
		end
	end

	local function destroy()
		folder:Destroy()
	end

	return {
		update = update,
		destroy = destroy,
	}
end

return table.freeze({
	new = new,
})
