--!strict
--[[
	Session: all plugin state and the operations on it.

	The UI only reads `session.state` and calls session functions; every
	state change fires `session.changed`. Recompilation is debounced: bursts
	of edits (dragging a part, Rojo syncing many files) cause one analysis.

	Engine code is user code that can be mid-edit, so calls into it are
	protected; an engine error is shown instead of breaking the plugin.
]]

local CoreGui = game:GetService("CoreGui")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local engineModule = require(script.Parent.engine)
local engineTypes = require(script.Parent.engine_types)
local format = require(script.Parent.format)
local maidModule = require(script.Parent.maid)
local preview = require(script.Parent.preview)
local roots = require(script.Parent.roots)
local settingsModule = require(script.Parent.settings)
local signal = require(script.Parent.signal)
local watcher = require(script.Parent.watcher)

type engine = engineModule.engine
type analysis = engineTypes.analysis
type outline_node = engineTypes.outline_node

local DEBOUNCE = 0.35

export type state = {
	engine: engine?,
	engineError: string?,
	root: Instance?,
	rootPath: roots.path?,
	-- A root was remembered for this place but no longer exists.
	missingRoot: roots.path?,
	analysis: analysis?,
	analysisError: string?,
	-- Bumped on every analysis, so views can skip work when unchanged.
	revision: number,
	selected: Instance?,
	expanded: { [Instance]: boolean },
	choosing: boolean,
	candidates: { roots.candidate },
	preview: preview.preview?,
	previewError: string?,
	-- Instance remembered by "Copy as reference target".
	clipboard: Instance?,
	message: string?,
}

export type session = {
	state: state,
	settings: settingsModule.store,
	changed: signal.signal<nil>,
	-- Fired when the user asks to reveal an Instance (tree scrolls to it).
	reveal: signal.signal<Instance>,
	maid: maidModule.maid,
	-- Internal.
	watchMaid: maidModule.maid,
	engineMaid: maidModule.maid,
	pending: number,
	ghosted: { [BasePart]: number },
}

local function emit(s: session)
	s.changed:fire(nil)
end

local function notify(s: session, message: string?)
	s.state.message = message
	emit(s)
end

-- Ghosting ---------------------------------------------------------------------

-- Models of the source (inline models and referenced models) in the outline.
local function sourceModels(a: analysis): { Model }
	local models: { Model } = {}
	local seen: { [Instance]: boolean } = {}
	local function add(instance: Instance?)
		if instance and instance:IsA("Model") and not seen[instance] then
			seen[instance] = true
			table.insert(models, instance)
		end
	end
	local function visit(node: outline_node)
		if node.kind == "model" then
			add(node.instance)
		elseif node.kind == "reference" then
			add(node.target)
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
	return models
end

local function unghost(s: session)
	for part, original in s.ghosted do
		if part.Parent then
			part.LocalTransparencyModifier = original
		end
	end
	table.clear(s.ghosted)
end

-- Makes the source models see-through while a preview is shown, using
-- LocalTransparencyModifier (not saved, no undo entry).
local function ghost(s: session)
	unghost(s)
	local a = s.state.analysis
	if not (s.settings.values.ghostSource and s.state.preview and a) then
		return
	end
	for _, model in sourceModels(a) do
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") then
				s.ghosted[descendant] = descendant.LocalTransparencyModifier
				descendant.LocalTransparencyModifier = 0.8
			end
		end
	end
end

-- Preview ----------------------------------------------------------------------

local function clearPreview(s: session)
	unghost(s)
	local current = s.state.preview
	if current then
		preview.destroy(current)
	end
	s.state.preview = nil
	s.state.previewError = nil
	emit(s)
end

local function generatePreview(s: session)
	local engine = s.state.engine
	local a = s.state.analysis
	unghost(s)
	if s.state.preview then
		preview.destroy(s.state.preview)
		s.state.preview = nil
	end
	if engine == nil or a == nil then
		s.state.previewError = "Nothing to preview: open a root first."
		emit(s)
		return
	end
	if not a.result.ok then
		s.state.previewError = "The floor has errors; fix them to preview."
		emit(s)
		return
	end
	local values = s.settings.values
	local generated = preview.generate(engine, a.result.val, {
		seed = values.seed,
		maxDepth = values.maxDepth,
		offset = Vector3.new(values.offset[1], values.offset[2], values.offset[3]),
		lock = values.lockPreview,
		planningParents = { CoreGui, ServerStorage },
		parent = Workspace,
	})
	if generated.ok then
		s.state.preview = generated.val
		s.state.previewError = nil
		ghost(s)
	else
		s.state.previewError = generated.err
	end
	emit(s)
end

-- Analysis ---------------------------------------------------------------------

local schedule: (s: session) -> ()

local function languageTags(engine: engine): { string }
	local TAG = engine.compiler.constants.TAG
	return {
		TAG.conditional,
		TAG.room,
		TAG.plug,
		TAG.optional,
		TAG.override,
		TAG.connection,
		TAG.removedAtomic,
	}
end

local function rewatch(s: session)
	s.watchMaid:clean()
	local engine = s.state.engine
	local root = s.state.root
	if engine == nil or root == nil or not s.settings.values.autoCompile then
		return
	end
	local subtrees: { Instance } = { root }
	local a = s.state.analysis
	if a then
		for _, def in a.definitions do
			table.insert(subtrees, def.instance)
		end
		-- Referenced models outside the hierarchies affect placement too.
		for _, model in sourceModels(a) do
			if not model:IsDescendantOf(root) then
				table.insert(subtrees, model)
			end
		end
	end
	s.watchMaid = watcher.watch(subtrees, languageTags(engine), function()
		schedule(s)
	end)
end

local function analyze(s: session)
	local engine = s.state.engine
	local root = s.state.root
	if engine == nil or root == nil then
		s.state.analysis = nil
		emit(s)
		return
	end
	if root.Parent == nil then
		s.state.analysisError = "The root was deleted."
		s.state.analysis = nil
		emit(s)
		return
	end
	-- Forget expansion state of deleted Instances.
	for instance in s.state.expanded do
		if instance.Parent == nil then
			s.state.expanded[instance] = nil
		end
	end
	local ok, value = pcall(engine.compiler.analyze, root)
	if ok then
		s.state.analysis = value
		s.state.analysisError = nil
	else
		s.state.analysis = nil
		s.state.analysisError = "The compiler raised an error: " .. tostring(value)
	end
	s.state.revision += 1
	rewatch(s)
	emit(s)
	if ok and s.settings.values.autoPreview and value.result.ok then
		generatePreview(s)
	elseif s.state.preview then
		-- Keep ghosting in sync with the (possibly changed) set of models.
		ghost(s)
	end
end

-- Debounced analysis after edits.
function schedule(s: session)
	s.pending += 1
	local ticket = s.pending
	task.delay(DEBOUNCE, function()
		if s.pending == ticket then
			analyze(s)
		end
	end)
end

-- Engine -----------------------------------------------------------------------

local function loadEngine(s: session)
	s.engineMaid:clean()
	local path = s.settings.values.enginePath
	local loaded = engineModule.load(path)
	if loaded.ok then
		s.state.engine = loaded.val
		s.state.engineError = nil
	else
		s.state.engine = nil
		s.state.engineError = loaded.err
	end
	-- Reload automatically when engine source changes.
	s.engineMaid = engineModule.watch(path, function()
		local ticket = s.pending + 1
		s.pending = ticket
		task.delay(DEBOUNCE, function()
			if s.pending == ticket then
				loadEngine(s)
				analyze(s)
			end
		end)
	end)
	emit(s)
end

-- Roots ------------------------------------------------------------------------

local function remember(s: session, path: roots.path?)
	local values = s.settings.values
	local key = roots.placeKey()
	if path then
		values.roots[key] = path
		values.recent[key] = settingsModule.pushRecent(values.recent[key] or {}, path)
	else
		values.roots[key] = nil
	end
	s.settings.save()
end

local function openRoot(s: session, instance: Instance)
	local engine = s.state.engine
	if engine and engine.compiler.identify(instance) ~= "assembly" and engine.compiler.identify(instance) ~= "reference" then
		notify(s, string.format("%s is not an assembly or a reference to one.", instance:GetFullName()))
		return
	end
	local path = roots.pathOf(instance)
	if path == nil then
		notify(s, "That Instance is not part of the place.")
		return
	end
	clearPreview(s)
	s.state.root = instance
	s.state.rootPath = path
	s.state.missingRoot = nil
	s.state.choosing = false
	s.state.selected = nil
	table.clear(s.state.expanded)
	remember(s, path)
	s.state.message = nil
	analyze(s)
end

local function openPath(s: session, path: roots.path)
	local instance = roots.resolve(path)
	if instance then
		openRoot(s, instance)
	else
		s.state.missingRoot = path
		notify(s, "Not found: " .. roots.describe(path))
	end
end

local function closeRoot(s: session)
	clearPreview(s)
	s.watchMaid:clean()
	s.state.root = nil
	s.state.rootPath = nil
	s.state.analysis = nil
	s.state.analysisError = nil
	s.state.selected = nil
	remember(s, nil)
	emit(s)
end

local function startChoosing(s: session)
	local engine = s.state.engine
	if engine == nil then
		notify(s, "Load the engine to find assemblies.")
		return
	end
	s.state.candidates = roots.discover(roots.topLevelAssembly(engine.compiler.identify))
	s.state.choosing = true
	emit(s)
end

local function stopChoosing(s: session)
	s.state.choosing = false
	emit(s)
end

-- Selection ----------------------------------------------------------------------

local function select(s: session, instance: Instance?)
	s.state.selected = instance
	emit(s)
end

-- Expands the ancestors of an Instance in the tree and selects it.
local function revealInstance(s: session, instance: Instance)
	local a = s.state.analysis
	if a == nil then
		return
	end
	local trail = format.ancestry(a, instance)
	if trail == nil then
		return
	end
	for i = 1, #trail - 1 do
		s.state.expanded[trail[i]] = true
	end
	s.state.selected = instance
	emit(s)
	s.reveal:fire(instance)
end

local function toggleExpanded(s: session, instance: Instance, current: boolean)
	s.state.expanded[instance] = not current
	emit(s)
end

-- Settings ---------------------------------------------------------------------

local function setValue(s: session, apply: (settingsModule.values) -> ())
	apply(s.settings.values)
	s.settings.save()
	emit(s)
end

-- Construction -------------------------------------------------------------------

local function new(plugin: Plugin): session
	local expanded: { [Instance]: boolean } = {}
	local s: session = {
		state = {
			engine = nil,
			engineError = nil,
			root = nil,
			rootPath = nil,
			missingRoot = nil,
			analysis = nil,
			analysisError = nil,
			revision = 0,
			selected = nil,
			expanded = expanded,
			choosing = false,
			candidates = {},
			preview = nil,
			previewError = nil,
			clipboard = nil,
			message = nil,
		},
		settings = settingsModule.load(plugin),
		changed = signal.new(),
		reveal = signal.new(),
		maid = maidModule.new(),
		watchMaid = maidModule.new(),
		engineMaid = maidModule.new(),
		pending = 0,
		ghosted = {},
	}
	return s
end

-- Starts the session: loads the engine and reopens the remembered root.
local function start(s: session)
	loadEngine(s)
	local remembered = s.settings.values.roots[roots.placeKey()]
	if remembered then
		openPath(s, remembered)
	end
end

local function destroy(s: session)
	unghost(s)
	if s.state.preview then
		preview.destroy(s.state.preview)
		s.state.preview = nil
	end
	s.watchMaid:clean()
	s.engineMaid:clean()
	s.maid:clean()
	-- Cancel pending analyses.
	s.pending += 1
end

return table.freeze({
	new = new,
	start = start,
	destroy = destroy,
	loadEngine = loadEngine,
	analyze = analyze,
	schedule = schedule,
	openRoot = openRoot,
	openPath = openPath,
	closeRoot = closeRoot,
	startChoosing = startChoosing,
	stopChoosing = stopChoosing,
	select = select,
	revealInstance = revealInstance,
	toggleExpanded = toggleExpanded,
	generatePreview = generatePreview,
	clearPreview = clearPreview,
	setValue = setValue,
	notify = notify,
	sourceModels = sourceModels,
	rewatch = rewatch,
	ghost = ghost,
})
