--!strict
--[[
	The dock widget's content.

		Root        path, Open… / Use selection / Close / Rebuild, status line
		Tree        the outline (or the root chooser while choosing)
		Details     everything known about the selected node
		Problems    every diagnostic; click to jump to it
		Edit        authoring actions on the Explorer selection
		Preview     seed, depth, offset, generate / clear, statistics
		View        live behaviour and visualisation toggles, engine location

	Dynamic lists are rebuilt on every refresh; text inputs are created once
	and only updated while unfocused, so typing is never interrupted.
]]

local Selection = game:GetService("Selection")

local result = require(script.Parent.Parent.result)
local actions = require(script.Parent.Parent.actions)
local engineTypes = require(script.Parent.Parent.engine_types)
local format = require(script.Parent.Parent.format)
local roots = require(script.Parent.Parent.roots)
local sessionModule = require(script.Parent.Parent.session)
local settingsModule = require(script.Parent.Parent.settings)
local theme = require(script.Parent.theme)
local tree = require(script.Parent.tree)
local widgets = require(script.Parent.widgets)
local maidModule = require(script.Parent.Parent.maid)

type session = sessionModule.session

export type panel = {
	refresh: () -> (),
	destroy: () -> (),
}

local MIN_TREE = 140
local DETAILS_HEIGHT = 110
local PROBLEMS_HEIGHT = 110

local function parseWhole(text: string): number?
	local n = tonumber((string.gsub(text, "%s", "")))
	if n and n == math.floor(n) then
		return n
	end
	return nil
end

local function parseVector(text: string): { number }?
	local parts = string.split(text, ",")
	if #parts ~= 3 then
		return nil
	end
	local out = {}
	for _, part in parts do
		local n = tonumber((string.gsub(part, "%s", "")))
		if n == nil then
			return nil
		end
		table.insert(out, n)
	end
	return out
end

local function parsePath(text: string): settingsModule.path?
	local out = {}
	for _, segment in string.split(text, "/") do
		local trimmed = string.match(segment, "^%s*(.-)%s*$") or ""
		if trimmed ~= "" then
			table.insert(out, trimmed)
		end
	end
	return if #out > 0 then out else nil
end

local function mount(widget: DockWidgetPluginGui, s: session): panel
	local m = maidModule.new()
	local c = theme.panel()

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.fromScale(1, 1)
	content.BackgroundColor3 = c.background
	content.BorderSizePixel = 0
	widgets.pad(content, 4)
	widgets.list(content, false, 4)
	content.Parent = widget
	m:give(content)

	-- Sections ------------------------------------------------------------------

	local header = widgets.section(content, "Root", c, 1)
	local headerRow = widgets.row(header, 1)
	local statusLine = widgets.paragraph(header, "", c, 2)
	local messageLine = widgets.paragraph(header, "", c, 3, c.dim)

	local treeBox = widgets.scroller(content, 240, c, 2)
	local details = widgets.section(content, "Details", c, 3)
	local detailsBox = widgets.scroller(details, DETAILS_HEIGHT, c, 1)
	local problems, problemsHeading = widgets.section(content, "Problems", c, 4)
	local problemsBox = widgets.scroller(problems, PROBLEMS_HEIGHT, c, 1)
	local edit = widgets.section(content, "Edit (acts on the Explorer selection)", c, 5)
	local editRows = widgets.stack(edit, 1)
	local previewSection = widgets.section(content, "Preview", c, 6)
	local previewInputs = widgets.row(previewSection, 1)
	local previewButtons = widgets.row(previewSection, 2)
	local previewStats = widgets.paragraph(previewSection, "", c, 3)
	local view = widgets.section(content, "View", c, 7)
	local viewToggles = widgets.row(view, 1)
	local engineRow = widgets.row(view, 2)
	local engineStatus = widgets.paragraph(view, "", c, 3)

	-- Layout: the tree takes the height left over by the other sections.
	local function relayout()
		local used = 0
		for _, child in content:GetChildren() do
			if child:IsA("GuiObject") and child ~= treeBox then
				used += child.AbsoluteSize.Y + 4
			end
		end
		local height = math.max(MIN_TREE, widget.AbsoluteSize.Y - used - 12)
		treeBox.Size = UDim2.new(1, 0, 0, height)
	end
	m:give(widget:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout))

	-- Inputs created once -----------------------------------------------------------

	local values = s.settings.values
	widgets.label(previewInputs, "Seed", c, 1)
	local seedBox = widgets.input(previewInputs, tostring(values.seed), 80, c, 2, function(text)
		local n = parseWhole(text)
		if n then
			sessionModule.setValue(s, function(v)
				v.seed = n
			end)
		else
			sessionModule.notify(s, "The seed must be a whole number.")
		end
	end)
	widgets.label(previewInputs, "Depth", c, 3)
	local depthBox = widgets.input(previewInputs, tostring(values.maxDepth), 40, c, 4, function(text)
		local n = parseWhole(text)
		if n and n >= 0 then
			sessionModule.setValue(s, function(v)
				v.maxDepth = n
			end)
		else
			sessionModule.notify(s, "The depth must be a whole number of at least 0.")
		end
	end)
	widgets.label(previewInputs, "Offset", c, 5)
	local function offsetText(): string
		local o = s.settings.values.offset
		return string.format("%g, %g, %g", o[1], o[2], o[3])
	end
	local offsetBox = widgets.input(previewInputs, offsetText(), 110, c, 6, function(text)
		local v = parseVector(text)
		if v then
			sessionModule.setValue(s, function(values_)
				values_.offset = v
			end)
		else
			sessionModule.notify(s, "Write the offset as x, y, z.")
		end
	end)

	widgets.label(engineRow, "Engine", c, 1)
	local engineBox = widgets.input(engineRow, roots.describe(values.enginePath), 200, c, 2, function(text)
		local p = parsePath(text)
		if p then
			sessionModule.setValue(s, function(v)
				v.enginePath = p
			end)
			sessionModule.loadEngine(s)
			sessionModule.analyze(s)
		else
			sessionModule.notify(s, "Write the engine path like: ServerStorage / modules / floorgen")
		end
	end)
	widgets.button(engineRow, "Reload engine", c, 3, function()
		sessionModule.loadEngine(s)
		sessionModule.analyze(s)
	end)

	local function setIfUnfocused(box: TextBox, text: string)
		if not box:IsFocused() then
			box.Text = text
		end
	end

	-- Helpers -----------------------------------------------------------------------

	local function regenerateIfShown()
		if s.state.preview or s.settings.values.autoPreview then
			sessionModule.generatePreview(s)
		end
	end

	local function context(): actions.context?
		local engine = s.state.engine
		if engine == nil then
			sessionModule.notify(s, "The engine is not loaded.")
			return nil
		end
		return { compiler = engine.compiler, root = s.state.root, selection = Selection:Get() }
	end

	local function run(action: (actions.context) -> result.result<string, string>)
		local ctx = context()
		if ctx == nil then
			return
		end
		local outcome = action(ctx)
		if outcome.ok then
			sessionModule.notify(s, outcome.val)
		else
			sessionModule.notify(s, outcome.err)
		end
	end

	local rowFrames: { [Instance]: GuiObject } = {}

	local function clear(container: Instance)
		for _, child in container:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end

	-- Refresh -----------------------------------------------------------------------

	local function refreshHeader()
		clear(headerRow)
		local state = s.state
		local rootText = if state.rootPath then roots.describe(state.rootPath) else "(no root open)"
		local rootLabel = widgets.label(headerRow, rootText, c, 1, if state.root then c.text else c.dim)
		rootLabel.Font = Enum.Font.SourceSansBold
		widgets.button(headerRow, "Open…", c, 2, function()
			if s.state.choosing then
				sessionModule.stopChoosing(s)
			else
				sessionModule.startChoosing(s)
			end
		end)
		widgets.button(headerRow, "Use selection", c, 3, function()
			local first = Selection:Get()[1]
			if first then
				sessionModule.openRoot(s, first)
			else
				sessionModule.notify(s, "Select an asm Configuration (or a reference to one) in the Explorer first.")
			end
		end)
		if state.root then
			widgets.button(headerRow, "Close", c, 4, function()
				sessionModule.closeRoot(s)
			end)
			widgets.button(headerRow, "Rebuild", c, 5, function()
				sessionModule.analyze(s)
			end)
		end

		local a = state.analysis
		if state.analysisError then
			statusLine.Text = state.analysisError
			statusLine.TextColor3 = theme.tone.error
		elseif a then
			local text, tone = format.summary(a)
			statusLine.Text = text
			statusLine.TextColor3 = if tone == "error"
				then theme.tone.error
				elseif tone == "warning" then theme.tone.warning
				else theme.tone.handled
		elseif state.missingRoot then
			statusLine.Text = "The remembered root was not found: " .. roots.describe(state.missingRoot)
			statusLine.TextColor3 = theme.tone.warning
		else
			statusLine.Text = "Open a root assembly to start."
			statusLine.TextColor3 = c.dim
		end
		messageLine.Text = state.message or ""
		messageLine.Visible = state.message ~= nil
	end

	local function refreshChooser()
		clear(treeBox)
		local state = s.state
		local order = 0
		local function line(text: string, color: Color3?)
			order += 1
			local l = widgets.label(treeBox, text, c, order, color)
			l.Font = Enum.Font.SourceSansBold
		end
		local function choice(p: roots.path)
			order += 1
			local b = widgets.button(treeBox, roots.describe(p), c, order, function()
				sessionModule.openPath(s, p)
			end)
			b.TextXAlignment = Enum.TextXAlignment.Left
		end
		line("Recent")
		local recent: { roots.path } = s.settings.values.recent[roots.placeKey()] or {}
		if #recent == 0 then
			line("  (none)", c.dim)
		end
		for _, p in recent do
			choice(p)
		end
		line(string.format("Assemblies in this place (%d)", #state.candidates))
		for _, candidate in state.candidates do
			choice(candidate.path)
		end
		if #state.candidates >= roots.MAX_CANDIDATES then
			line(string.format("  (showing the first %d)", roots.MAX_CANDIDATES), c.dim)
		end
	end

	local function refreshTree()
		local a = s.state.analysis
		if a == nil then
			clear(treeBox)
			rowFrames = {}
			return
		end
		local rows = format.flatten(a, s.state.expanded, 3)
		rowFrames = tree.render(treeBox, rows, s.state.selected, a.result.ok, c, {
			select = function(instance)
				sessionModule.select(s, instance)
				Selection:Set({ instance })
			end,
			toggle = function(instance, expanded)
				sessionModule.toggleExpanded(s, instance, expanded)
			end,
			activate = function(instance)
				local node = format.findNode(a, instance)
				local target = if node then node.target else nil
				if target then
					Selection:Set({ target })
					sessionModule.revealInstance(s, target)
				end
			end,
		})
	end

	local function refreshDetails()
		clear(detailsBox)
		local a = s.state.analysis
		local selected = s.state.selected
		local node = if a and selected then format.findNode(a, selected) else nil
		if node then
			widgets.paragraph(detailsBox, format.details(node), c, 1, nil, true)
		else
			widgets.paragraph(detailsBox, "Select a node in the tree or the Explorer.", c, 1, c.dim)
		end
	end

	local function refreshProblems()
		clear(problemsBox)
		local a = s.state.analysis
		local list: { engineTypes.diagnostic } = if a then a.diagnostics else {}
		problemsHeading.Text = string.format("Problems (%d)", #list)
		if #list == 0 then
			widgets.paragraph(problemsBox, if a then "No problems." else "", c, 1, c.dim)
			return
		end
		for i, d in list do
			local b = widgets.button(problemsBox, format.diagnosticLine(d), c, i, function()
				local instance = d.instance
				if instance then
					Selection:Set({ instance })
					sessionModule.revealInstance(s, instance)
				end
				if d.hint then
					sessionModule.notify(s, "Hint: " .. d.hint)
				end
			end)
			b.BackgroundTransparency = 1
			b.TextXAlignment = Enum.TextXAlignment.Left
			b.Font = widgets.MONO
			b.TextSize = 13
			b.TextColor3 = if d.severity == "error" then theme.tone.error else theme.tone.warning
		end
	end

	local function refreshEdit()
		clear(editRows)
		local engine = s.state.engine
		if engine == nil then
			widgets.paragraph(editRows, "Load the engine to edit.", c, 1, c.dim)
			return
		end
		local TAG = engine.compiler.constants.TAG
		local add = widgets.row(editRows, 1)
		widgets.label(add, "Add", c, 0, c.dim)
		local function addButton(kind: actions.container_kind, order: number)
			widgets.button(add, kind, c, order, function()
				run(function(ctx)
					return actions.addNode(ctx, kind)
				end)
			end)
		end
		addButton("assembly", 1)
		addButton("try", 2)
		addButton("pick", 3)
		addButton("each", 4)
		widgets.button(add, "Wrap in try", c, 10, function()
			run(actions.wrapInTry)
		end)

		local tags = widgets.row(editRows, 2)
		widgets.label(tags, "Toggle", c, 0, c.dim)
		local tagButtons = {
			{ "optional", TAG.optional },
			{ "conditional", TAG.conditional },
			{ "room", TAG.room },
			{ "plug", TAG.plug },
			{ "override", TAG.override },
		}
		for i, entry in tagButtons do
			widgets.button(tags, entry[1], c, i, function()
				run(function(ctx)
					return actions.toggleTag(ctx, entry[2])
				end)
			end)
		end

		local more = widgets.row(editRows, 3)
		widgets.button(more, "Copy as ref target", c, 1, function()
			local first = Selection:Get()[1]
			s.state.clipboard = first
			sessionModule.notify(s, if first then "Reference target: " .. first:GetFullName() else "Nothing selected.")
		end)
		local clipboard = s.state.clipboard
		widgets.button(more, "Paste reference", c, 2, function()
			if clipboard == nil then
				sessionModule.notify(s, "Copy a reference target first.")
				return
			end
			run(function(ctx)
				return actions.pasteReference(ctx, clipboard)
			end)
		end)
		widgets.button(more, "Add connection", c, 3, function()
			run(actions.addConnection)
		end)
		widgets.button(more, "Add overlap volume", c, 4, function()
			run(actions.addOverlap)
		end)
	end

	local function refreshPreview()
		setIfUnfocused(seedBox, tostring(s.settings.values.seed))
		setIfUnfocused(depthBox, tostring(s.settings.values.maxDepth))
		setIfUnfocused(offsetBox, offsetText())

		clear(previewButtons)
		widgets.button(previewButtons, "Generate", c, 1, function()
			sessionModule.generatePreview(s)
		end)
		widgets.button(previewButtons, "Clear", c, 2, function()
			sessionModule.clearPreview(s)
		end)
		widgets.button(previewButtons, "Seed -1", c, 3, function()
			sessionModule.setValue(s, function(v)
				v.seed -= 1
			end)
			regenerateIfShown()
		end)
		widgets.button(previewButtons, "Seed +1", c, 4, function()
			sessionModule.setValue(s, function(v)
				v.seed += 1
			end)
			regenerateIfShown()
		end)
		widgets.button(previewButtons, "Random seed", c, 5, function()
			sessionModule.setValue(s, function(v)
				v.seed = math.random(1, 2 ^ 31 - 1)
			end)
			regenerateIfShown()
		end)

		local state = s.state
		local p = state.preview
		if state.previewError then
			previewStats.Text = state.previewError
			previewStats.TextColor3 = theme.tone.error
		elseif p then
			local failures = {}
			local reasons = {}
			for reason in p.plan.stats.failures do
				table.insert(reasons, reason)
			end
			table.sort(reasons)
			for _, reason in reasons do
				table.insert(failures, string.format("%s %d", reason, p.plan.stats.failures[reason]))
			end
			previewStats.Text = string.format(
				"Seed %d: %d models, %d node runs, planned in %.1f ms, spawned in %.1f ms.\nHandled failures: %s",
				p.seed,
				#p.plan.emissions,
				p.plan.stats.executions,
				p.planning * 1000,
				p.committing * 1000,
				if #failures > 0 then table.concat(failures, ", ") else "none"
			)
			previewStats.TextColor3 = c.text
		else
			previewStats.Text = "No preview."
			previewStats.TextColor3 = c.dim
		end
	end

	local function refreshView()
		clear(viewToggles)
		local v = s.settings.values
		type entry = {
			text: string,
			value: boolean,
			apply: (settingsModule.values, boolean) -> (),
			after: (() -> ())?,
		}
		local entries: { entry } = {
			{
				text = "Live recompile",
				value = v.autoCompile,
				apply = function(x, on)
					x.autoCompile = on
				end,
				after = function()
					sessionModule.rewatch(s)
				end,
			},
			{
				text = "Live preview",
				value = v.autoPreview,
				apply = function(x, on)
					x.autoPreview = on
				end,
				after = regenerateIfShown,
			},
			{
				text = "Ghost source",
				value = v.ghostSource,
				apply = function(x, on)
					x.ghostSource = on
				end,
				after = function()
					sessionModule.ghost(s)
				end,
			},
			{
				text = "Lock preview",
				value = v.lockPreview,
				apply = function(x, on)
					x.lockPreview = on
				end,
			},
			{
				text = "Connections",
				value = v.showConnections,
				apply = function(x, on)
					x.showConnections = on
				end,
			},
			{
				text = "Overlaps",
				value = v.showOverlaps,
				apply = function(x, on)
					x.showOverlaps = on
				end,
			},
			{
				text = "Problems",
				value = v.showProblems,
				apply = function(x, on)
					x.showProblems = on
				end,
			},
			{
				text = "Failures",
				value = v.showFailures,
				apply = function(x, on)
					x.showFailures = on
				end,
			},
		}
		for i, entry in entries do
			widgets.toggle(viewToggles, entry.text, entry.value, c, i, function(on)
				sessionModule.setValue(s, function(x)
					entry.apply(x, on)
				end)
				local after = entry.after
				if after then
					after()
				end
			end)
		end

		setIfUnfocused(engineBox, roots.describe(v.enginePath))
		local engine = s.state.engine
		if engine then
			engineStatus.Text = "Engine loaded from " .. engine.location .. " (reloads when its source changes)."
			engineStatus.TextColor3 = c.dim
		else
			engineStatus.Text = s.state.engineError or "Engine not loaded."
			engineStatus.TextColor3 = theme.tone.error
		end
	end

	local function refresh()
		refreshHeader()
		if s.state.choosing then
			refreshChooser()
		else
			refreshTree()
		end
		refreshDetails()
		refreshProblems()
		refreshEdit()
		refreshPreview()
		refreshView()
		task.defer(relayout)
	end

	m:give(s.changed:connect(function()
		refresh()
	end))
	m:give(s.reveal:connect(function(instance)
		local frame = rowFrames[instance]
		if frame then
			task.defer(tree.scrollTo, treeBox, frame)
		end
	end))

	refresh()

	return {
		refresh = refresh,
		destroy = function()
			m:clean()
		end,
	}
end

return table.freeze({
	mount = mount,
})
