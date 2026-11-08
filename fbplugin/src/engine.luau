--!strict
--[[
	Engine loading.

	The plugin does not bundle the compiler and builder. It loads them from the
	open place (by default ServerStorage.modules.floorgen, where the project's Rojo
	setup puts them), so the plugin always runs exactly the engine the game
	ships with.

	Studio caches `require` results even in edit mode, so the engine folder is
	cloned before requiring; requiring a fresh clone runs the current source.
	Source changes in the engine folder (for example from Rojo sync) mark the
	loaded engine as stale so it can be reloaded.
]]

local result = require(script.Parent.result)
local engineTypes = require(script.Parent.engine_types)
local maidModule = require(script.Parent.maid)
local roots = require(script.Parent.roots)

export type engine = {
	compiler: engineTypes.compiler,
	builder: engineTypes.builder,
	-- Where it was loaded from, for display.
	location: string,
}

local function describe(value: unknown): string
	return if type(value) == "table" then "table" else typeof(value)
end

-- Requires a cloned ModuleScript. Engine code is user code that may be
-- mid-edit, so errors while running it are expected and caught here.
local function requireFresh(module: Instance): result.result<unknown, string>
	if not module:IsA("ModuleScript") then
		return result.err(string.format("%s is not a ModuleScript.", module:GetFullName()))
	end
	local ok, value = pcall(require, module)
	if not ok then
		return result.err(string.format("Requiring %s failed: %s", module.Name, tostring(value)))
	end
	return result.ok(value)
end

local function hasFunctions(value: unknown, names: { string }): boolean
	if type(value) ~= "table" then
		return false
	end
	local t = value :: { [string]: unknown }
	for _, name in names do
		if type(t[name]) ~= "function" then
			return false
		end
	end
	return true
end

local function load(path: roots.path): result.result<engine, string>
	local folder = roots.resolve(path)
	if folder == nil then
		return result.err(
			string.format("Engine not found at %s. Sync the project with Rojo, or change the engine path.", roots.describe(path))
		)
	end
	if folder:FindFirstChild("compiler") == nil or folder:FindFirstChild("builder") == nil then
		return result.err(string.format("%s must contain the 'compiler' and 'builder' modules.", roots.describe(path)))
	end

	local copy = folder:Clone()
	local compilerModule = copy:FindFirstChild("compiler")
	local builderModule = copy:FindFirstChild("builder")
	if compilerModule == nil or builderModule == nil then
		return result.err("The engine modules could not be copied (are they Archivable?).")
	end

	local compiler = requireFresh(compilerModule)
	if not compiler.ok then
		return compiler
	end
	if not hasFunctions(compiler.val, { "analyze", "identify", "formatDiagnostic" }) then
		return result.err(string.format("The compiler module has an unexpected shape (%s).", describe(compiler.val)))
	end

	local builder = requireFresh(builderModule)
	if not builder.ok then
		return builder
	end
	if not hasFunctions(builder.val, { "plan", "commit" }) then
		return result.err(string.format("The builder module has an unexpected shape (%s).", describe(builder.val)))
	end

	-- The shapes were checked above; the detailed types are documented in
	-- engine_types.luau and mirror the engine's own public types.
	return result.ok({
		compiler = compiler.val :: any,
		builder = builder.val :: any,
		location = roots.describe(path),
	})
end

-- Calls `onChanged` whenever engine source code changes. Returns a maid.
local function watch(path: roots.path, onChanged: () -> ()): maidModule.maid
	local m = maidModule.new()
	local folder = roots.resolve(path)
	if folder == nil then
		return m
	end
	local function watchModule(instance: Instance)
		if instance:IsA("ModuleScript") then
			m:give(instance:GetPropertyChangedSignal("Source"):Connect(onChanged))
		end
	end
	for _, descendant in folder:GetDescendants() do
		watchModule(descendant)
	end
	m:give(folder.DescendantAdded:Connect(function(instance)
		watchModule(instance)
		onChanged()
	end))
	m:give(folder.DescendantRemoving:Connect(function()
		onChanged()
	end))
	return m
end

return table.freeze({
	load = load,
	watch = watch,
})
