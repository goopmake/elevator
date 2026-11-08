--!strict
--[[
	Primitive UI building blocks. Plain frames, labels, buttons and text boxes
	with no animation; every builder parents the new object and returns it.
]]

local theme = require(script.Parent.theme)

export type colors = theme.panel

local ROW = 20
local FONT = Enum.Font.SourceSans
local MONO = Enum.Font.Code

local function list(parent: Instance, horizontal: boolean, padding: number): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, padding)
	layout.Parent = parent
	return layout
end

local function pad(parent: Instance, pixels: number)
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, pixels)
	padding.PaddingRight = UDim.new(0, pixels)
	padding.PaddingTop = UDim.new(0, pixels)
	padding.PaddingBottom = UDim.new(0, pixels)
	padding.Parent = parent
end

-- A transparent container that grows to fit its children vertically.
local function stack(parent: Instance, order: number, padding: number?): Frame
	local frame = Instance.new("Frame")
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.LayoutOrder = order
	list(frame, false, padding or 2)
	frame.Parent = parent
	return frame
end

-- A horizontal row of controls that wraps when too narrow.
local function row(parent: Instance, order: number): Frame
	local frame = Instance.new("Frame")
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, ROW)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.LayoutOrder = order
	local layout = list(frame, true, 4)
	layout.Wraps = true
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	frame.Parent = parent
	return frame
end

local function label(parent: Instance, text: string, c: colors, order: number, color: Color3?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(0, 0, 0, ROW)
	l.AutomaticSize = Enum.AutomaticSize.X
	l.Font = FONT
	l.TextSize = 14
	l.TextColor3 = color or c.text
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = text
	l.LayoutOrder = order
	l.Parent = parent
	return l
end

-- A full-width, wrapping, multi-line text block.
local function paragraph(parent: Instance, text: string, c: colors, order: number, color: Color3?, mono: boolean?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, 0)
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.Font = if mono then MONO else FONT
	l.TextSize = if mono then 13 else 14
	l.TextColor3 = color or c.text
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.TextWrapped = true
	l.RichText = false
	l.Text = text
	l.LayoutOrder = order
	l.Parent = parent
	return l
end

local function button(parent: Instance, text: string, c: colors, order: number, onClick: () -> ()): TextButton
	local b = Instance.new("TextButton")
	b.AutoButtonColor = true
	b.BackgroundColor3 = c.button
	b.BorderColor3 = c.border
	b.BorderSizePixel = 1
	b.Size = UDim2.new(0, 0, 0, ROW)
	b.AutomaticSize = Enum.AutomaticSize.X
	b.Font = FONT
	b.TextSize = 14
	b.TextColor3 = c.buttonText
	b.Text = " " .. text .. " "
	b.LayoutOrder = order
	b.Activated:Connect(onClick)
	b.Parent = parent
	return b
end

local function toggle(parent: Instance, text: string, value: boolean, c: colors, order: number, onChange: (boolean) -> ()): TextButton
	return button(parent, (if value then "[x] " else "[ ] ") .. text, c, order, function()
		onChange(not value)
	end)
end

-- A text box that calls `onCommit` when focus is lost with Enter.
local function input(parent: Instance, text: string, width: number, c: colors, order: number, onCommit: (string) -> ()): TextBox
	local box = Instance.new("TextBox")
	box.BackgroundColor3 = c.input
	box.BorderColor3 = c.border
	box.BorderSizePixel = 1
	box.Size = UDim2.new(0, width, 0, ROW)
	box.Font = MONO
	box.TextSize = 13
	box.TextColor3 = c.text
	box.ClearTextOnFocus = false
	box.Text = text
	box.LayoutOrder = order
	box.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			onCommit(box.Text)
		else
			box.Text = text
		end
	end)
	box.Parent = parent
	return box
end

-- A titled section with a background. Returns the frame and its heading.
local function section(parent: Instance, title: string, c: colors, order: number): (Frame, TextLabel)
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = c.section
	frame.BorderSizePixel = 0
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.LayoutOrder = order
	pad(frame, 4)
	list(frame, false, 3)
	local heading = label(frame, title, c, 0, c.dim)
	heading.Font = Enum.Font.SourceSansBold
	frame.Parent = parent
	return frame, heading
end

local function scroller(parent: Instance, height: number, c: colors, order: number): ScrollingFrame
	local frame = Instance.new("ScrollingFrame")
	frame.BackgroundColor3 = c.background
	frame.BorderColor3 = c.border
	frame.BorderSizePixel = 1
	frame.Size = UDim2.new(1, 0, 0, height)
	frame.CanvasSize = UDim2.new(0, 0, 0, 0)
	frame.AutomaticCanvasSize = Enum.AutomaticSize.XY
	frame.ScrollBarThickness = 8
	frame.ScrollingDirection = Enum.ScrollingDirection.XY
	frame.LayoutOrder = order
	list(frame, false, 0)
	frame.Parent = parent
	return frame
end

local function escape(text: string): string
	return (string.gsub(string.gsub(string.gsub(text, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"))
end

return table.freeze({
	ROW = ROW,
	FONT = FONT,
	MONO = MONO,
	list = list,
	pad = pad,
	stack = stack,
	row = row,
	label = label,
	paragraph = paragraph,
	button = button,
	toggle = toggle,
	input = input,
	section = section,
	scroller = scroller,
	escape = escape,
})
