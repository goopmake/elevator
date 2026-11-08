--!strict
--[[
	The node tree: one row per visible outline node.

		[+] [asm] Lobby  {optional}   1 warning  may fail · handled

	Click selects the Instance (Explorer and Properties follow), the +/- box
	expands or collapses, double click on a reference selects its target.
	Label colour shows the node's own problems; a collapsed node whose subtree
	has an error shows a red "!" in its toggle.
]]

local format = require(script.Parent.Parent.format)
local theme = require(script.Parent.theme)
local widgets = require(script.Parent.widgets)

export type callbacks = {
	select: (instance: Instance) -> (),
	toggle: (instance: Instance, expanded: boolean) -> (),
	activate: (instance: Instance) -> (),
}

local INDENT = 14
local ROW_HEIGHT = 18
local DOUBLE_CLICK = 0.35

local TONE_COLORS: { [format.tone]: Color3 } = {
	error = theme.tone.error,
	warning = theme.tone.warning,
	fail = theme.tone.fail,
	handled = theme.tone.handled,
	info = theme.tone.info,
	muted = theme.tone.muted,
}

local lastClick: { instance: Instance?, at: number } = { instance = nil, at = 0 }

-- Renders rows into `container` and returns the row frame of every Instance.
local function render(
	container: ScrollingFrame,
	rows: { format.row },
	selected: Instance?,
	compiledOk: boolean,
	c: theme.panel,
	callbacks: callbacks
): { [Instance]: GuiObject }
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local frames: { [Instance]: GuiObject } = {}
	for index, row in rows do
		local frame = Instance.new("Frame")
		frame.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		frame.AutomaticSize = Enum.AutomaticSize.X
		frame.BorderSizePixel = 0
		frame.LayoutOrder = index
		frame.BackgroundColor3 = c.selected
		frame.BackgroundTransparency = 1

		local node = row.node
		if node == nil then
			local header = widgets.label(frame, row.header or "", c, 0, c.dim)
			header.Font = Enum.Font.SourceSansBold
			header.Size = UDim2.new(0, 0, 0, ROW_HEIGHT)
			frame.Parent = container
			continue
		end
		local instance = node.instance
		if instance == selected then
			frame.BackgroundTransparency = 0
		end

		local toggleText = if row.hasChildren then (if row.expanded then "-" else "+") else ""
		if row.hasChildren and not row.expanded and format.subtreeHasErrors(node) then
			toggleText ..= "!"
		end
		local toggleButton = Instance.new("TextButton")
		toggleButton.BackgroundTransparency = 1
		toggleButton.Position = UDim2.fromOffset(row.depth * INDENT, 0)
		toggleButton.Size = UDim2.fromOffset(16, ROW_HEIGHT)
		toggleButton.Font = widgets.MONO
		toggleButton.TextSize = 13
		toggleButton.TextColor3 = if string.find(toggleText, "!", 1, true) then theme.tone.error else c.dim
		toggleButton.Text = toggleText
		toggleButton.Parent = frame
		if row.hasChildren then
			toggleButton.Activated:Connect(function()
				callbacks.toggle(instance, row.expanded)
			end)
		end

		local labelColor = TONE_COLORS[format.rowTone(node)] or c.text
		local parts = {
			string.format('<font color="%s">%s</font>', theme.hex(labelColor), widgets.escape(format.rowText(node))),
		}
		for _, badge in format.badges(node, compiledOk) do
			local color = TONE_COLORS[badge.tone] or c.dim
			table.insert(parts, string.format('<font color="%s">%s</font>', theme.hex(color), widgets.escape(badge.text)))
		end

		local text = Instance.new("TextButton")
		text.BackgroundTransparency = 1
		text.Position = UDim2.fromOffset(row.depth * INDENT + 18, 0)
		text.Size = UDim2.fromOffset(0, ROW_HEIGHT)
		text.AutomaticSize = Enum.AutomaticSize.X
		text.Font = widgets.MONO
		text.TextSize = 13
		text.RichText = true
		text.TextXAlignment = Enum.TextXAlignment.Left
		text.Text = table.concat(parts, "   ")
		text.Parent = frame
		text.Activated:Connect(function()
			local now = os.clock()
			if lastClick.instance == instance and now - lastClick.at < DOUBLE_CLICK then
				callbacks.activate(instance)
			else
				callbacks.select(instance)
			end
			lastClick.instance = instance
			lastClick.at = now
		end)

		frame.Parent = container
		frames[instance] = frame
	end
	return frames
end

-- Scrolls so that `frame` is visible.
local function scrollTo(container: ScrollingFrame, frame: GuiObject)
	local top = frame.AbsolutePosition.Y - container.AbsolutePosition.Y + container.CanvasPosition.Y
	local view = container.AbsoluteWindowSize.Y
	local current = container.CanvasPosition.Y
	if top < current or top + ROW_HEIGHT > current + view then
		container.CanvasPosition = Vector2.new(container.CanvasPosition.X, math.max(0, top - view / 3))
	end
end

return table.freeze({
	render = render,
	scrollTo = scrollTo,
	ROW_HEIGHT = ROW_HEIGHT,
})
