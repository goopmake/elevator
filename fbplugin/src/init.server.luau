--!strict
--[[
	Floor Builder plugin.

	Toolbar button toggles a dock widget that works on one opened root
	assembly at a time (remembered per place): a live annotated tree of the
	floor program, its problems, authoring actions, previews generated with
	the project's own builder, and in-world visualisations.

	All resources are owned by a maid and released on plugin.Unloading, which
	must not yield.
]]

local CoreGui = game:GetService("CoreGui")
local Selection = game:GetService("Selection")

local format = require(script.format)
local maidModule = require(script.maid)
local panelModule = require(script.ui.panel)
local sessionModule = require(script.session)
local visualsModule = require(script.visuals)

local maid = maidModule.new()

local toolbar = plugin:CreateToolbar("Floor Builder")
local button = toolbar:CreateButton(
	"FloorBuilderToggle",
	"Open the floor builder panel",
	"",
	"Floor Builder"
)
button.ClickableWhenViewportHidden = true

local info = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 440, 720, 320, 320)
local widget = plugin:CreateDockWidgetPluginGuiAsync("FloorBuilderPanel", info)
widget.Title = "Floor Builder"
widget.Name = "FloorBuilder"
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

maid:give(button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end))
maid:give(widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	button:SetActive(widget.Enabled)
end))
button:SetActive(widget.Enabled)

local session = sessionModule.new(plugin)
local visuals = visualsModule.new(CoreGui)
local panel = panelModule.mount(widget, session)

local function updateVisuals()
	local state = session.state
	local values = session.settings.values
	local a = state.analysis
	local preview = state.preview
	local trace = if preview then preview.plan.trace else nil
	if not widget.Enabled then
		visuals.update({
			analysis = nil,
			models = {},
			selected = nil,
			failures = {},
			constants = nil,
			show = { connections = false, overlaps = false, problems = false, failures = false },
		})
		return
	end
	visuals.update({
		analysis = a,
		models = if a then sessionModule.sourceModels(a) else {},
		selected = state.selected,
		failures = if trace then trace.failures else {},
		constants = if state.engine then state.engine.compiler.constants else nil,
		show = {
			connections = values.showConnections,
			overlaps = values.showOverlaps,
			problems = values.showProblems,
			failures = values.showFailures,
		},
	})
end

maid:give(session.changed:connect(updateVisuals))
maid:give(widget:GetPropertyChangedSignal("Enabled"):Connect(updateVisuals))

-- Keep the tree in sync with the Explorer selection.
maid:give(Selection.SelectionChanged:Connect(function()
	local first = Selection:Get()[1]
	local a = session.state.analysis
	if first and a and first ~= session.state.selected and format.findNode(a, first) then
		sessionModule.revealInstance(session, first)
	end
end))

-- Rebuild the panel with new colours when the Studio theme changes.
maid:give(settings().Studio.ThemeChanged:Connect(function()
	panel.destroy()
	panel = panelModule.mount(widget, session)
end))

plugin.Unloading:Connect(function()
	panel.destroy()
	visuals.destroy()
	sessionModule.destroy(session)
	maid:clean()
end)

sessionModule.start(session)
updateVisuals()
