--!strict
--[[
	Colours. Panel colours follow the Studio theme (light or dark); status
	colours are fixed so their meaning never changes.
]]

local function studio(color: Enum.StudioStyleGuideColor, modifier: Enum.StudioStyleGuideModifier?): Color3
	local current = settings().Studio.Theme
	return current:GetColor(color, modifier or Enum.StudioStyleGuideModifier.Default)
end

local function panel()
	return {
		background = studio(Enum.StudioStyleGuideColor.MainBackground),
		section = studio(Enum.StudioStyleGuideColor.Titlebar),
		text = studio(Enum.StudioStyleGuideColor.MainText),
		dim = studio(Enum.StudioStyleGuideColor.DimmedText),
		button = studio(Enum.StudioStyleGuideColor.Button),
		buttonText = studio(Enum.StudioStyleGuideColor.ButtonText),
		input = studio(Enum.StudioStyleGuideColor.InputFieldBackground),
		border = studio(Enum.StudioStyleGuideColor.Border),
		selected = studio(Enum.StudioStyleGuideColor.Item, Enum.StudioStyleGuideModifier.Selected),
		hover = studio(Enum.StudioStyleGuideColor.Item, Enum.StudioStyleGuideModifier.Hover),
	}
end

export type panel = typeof(panel())

-- Status colours for text.
local tone = table.freeze({
	error = Color3.fromRGB(235, 87, 87),
	warning = Color3.fromRGB(240, 160, 60),
	fail = Color3.fromRGB(220, 130, 200),
	handled = Color3.fromRGB(110, 190, 120),
	info = Color3.fromRGB(100, 160, 240),
	muted = Color3.fromRGB(140, 140, 140),
})

-- In-world visualisation colours.
local visual = table.freeze({
	connection = Color3.fromRGB(60, 210, 90),
	overlap = Color3.fromRGB(230, 60, 60),
	error = Color3.fromRGB(235, 60, 60),
	warning = Color3.fromRGB(245, 160, 40),
	selection = Color3.fromRGB(60, 190, 255),
	failure = Color3.fromRGB(255, 70, 160),
})

local function hex(color: Color3): string
	return string.format(
		"#%02X%02X%02X",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5)
	)
end

return table.freeze({
	panel = panel,
	tone = tone,
	visual = visual,
	hex = hex,
})
