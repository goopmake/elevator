--[[
	Headless test runner (Lune).

		lune run scripts/run_tests [filter]

	Builds the Rojo project into a place file, loads it with Lune's Roblox
	library and runs every ModuleScript whose name ends in ".spec" with a small
	TestEZ-compatible API (describe / it / expect). ModuleScripts are executed
	with Roblox semantics: `script`, `game` and instance-based `require`.

	The spec files are plain TestEZ specs, so they also run unchanged under
	TestEZ inside Studio.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local stdio = require("@lune/stdio")

local filter = process.args[1]

-- Build -------------------------------------------------------------------

local placePath = ".test-place.rbxl"
local built = process.exec("rojo", { "build", "default.project.json", "-o", placePath })
if not built.ok then
	print(built.stderr)
	error("rojo build failed")
end
local game = roblox.deserializePlace(fs.readFile(placePath))
fs.removeFile(placePath)

-- The plugin is a separate Rojo project; its modules and specs are loaded
-- into ServerStorage of the test place so they can use the engine.
local pluginPath = ".test-plugin.rbxm"
local builtPlugin = process.exec("rojo", { "build", "fbplugin", "-o", pluginPath })
if not builtPlugin.ok then
	print(builtPlugin.stderr)
	error("rojo build of the plugin failed")
end
for _, instance in roblox.deserializeModel(fs.readFile(pluginPath)) do
	instance.Parent = game:GetService("ServerStorage")
end
fs.removeFile(pluginPath)

-- Instance identity ---------------------------------------------------------
--[[
	In Roblox every reference to the same Instance is the same userdata, so
	Instances are valid table keys (the compiler relies on this). Lune creates a
	new userdata on every access, so we wrap each Instance in a single interned
	proxy table that forwards everything to the real Instance.
]]

local realOf: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any
local buckets: { [string]: { { any } } } = {}
local proxyMeta: { [string]: any } = {}

local wrap: (any) -> any

local function unwrap(value: any): any
	if type(value) == "table" and realOf[value] ~= nil then
		return realOf[value]
	end
	return value
end

local function wrapAll(...: any): ...any
	local values = table.pack(...)
	for i = 1, values.n do
		values[i] = wrap(values[i])
	end
	return table.unpack(values, 1, values.n)
end

function wrap(value: any): any
	if typeof(value) == "Instance" then
		local className = value.ClassName
		local bucket = buckets[className]
		if bucket == nil then
			bucket = {}
			buckets[className] = bucket
		end
		for _, pair in bucket do
			if pair[1] == value then
				return pair[2]
			end
		end
		local proxy = setmetatable({}, proxyMeta)
		realOf[proxy] = value
		table.insert(bucket, { value, proxy })
		return proxy
	elseif type(value) == "table" and getmetatable(value) == nil and realOf[value] == nil then
		local copy = {}
		for k, v in value do
			copy[k] = wrap(v)
		end
		return copy
	end
	return value
end

-- Model pivot methods are not implemented by Lune; emulate them for models
-- with a PrimaryPart (pivot = PrimaryPart.CFrame).
local function modelPivot(real: any): any
	local primary = real.PrimaryPart
	if primary == nil then
		error("GetPivot emulation needs a PrimaryPart")
	end
	return primary.CFrame
end

local emulatedModelMethods: { [string]: (any, ...any) -> ...any } = {
	GetPivot = function(real)
		return modelPivot(real)
	end,
	PivotTo = function(real, target)
		local delta = target * modelPivot(real):Inverse()
		for _, descendant in real:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.CFrame = delta * descendant.CFrame
			end
		end
	end,
}

proxyMeta.__index = function(proxy, key)
	local real = realOf[proxy]
	local emulated = emulatedModelMethods[key]
	if emulated and real.ClassName == "Model" then
		return function(_self, ...)
			local args = table.pack(...)
			for i = 1, args.n do
				args[i] = unwrap(args[i])
			end
			return wrapAll(emulated(real, table.unpack(args, 1, args.n)))
		end
	end
	local value = real[key]
	if type(value) == "function" then
		return function(_self, ...)
			local args = table.pack(...)
			for i = 1, args.n do
				args[i] = unwrap(args[i])
			end
			return wrapAll(value(real, table.unpack(args, 1, args.n)))
		end
	end
	return wrap(value)
end
proxyMeta.__newindex = function(proxy, key, value)
	realOf[proxy][key] = unwrap(value)
end
proxyMeta.__tostring = function(proxy)
	return tostring(realOf[proxy])
end

local function emulatedTypeof(value: any): string
	if type(value) == "table" and realOf[value] ~= nil then
		return "Instance"
	end
	return typeof(value)
end

-- Random emulation (Park-Miller). Deterministic like Roblox's Random, but
-- with a different sequence: tests must not depend on concrete values.
local RandomLibrary = table.freeze({
	new = function(seed: number?)
		local state = (math.floor(seed or 0) % 2147483646) + 1
		local rng = {}
		function rng.NextInteger(_self, min: number, max: number): number
			state = (state * 48271) % 2147483647
			return min + (state % (max - min + 1))
		end
		function rng.NextNumber(_self): number
			state = (state * 48271) % 2147483647
			return state / 2147483647
		end
		return rng
	end,
})

local yields = 0
local TaskLibrary = table.freeze({
	wait = function()
		yields += 1
		return 0
	end,
})

local InstanceLibrary = table.freeze({
	new = function(className: string, parent: any?)
		local instance = roblox.Instance.new(className)
		if parent ~= nil then
			instance.Parent = unwrap(parent)
		end
		return wrap(instance)
	end,
})

-- Module loader -----------------------------------------------------------

local baseGlobals = {
	assert = assert,
	error = error,
	getmetatable = getmetatable,
	ipairs = ipairs,
	next = next,
	pairs = pairs,
	pcall = pcall,
	print = print,
	rawequal = rawequal,
	rawget = rawget,
	rawlen = rawlen,
	rawset = rawset,
	select = select,
	setmetatable = setmetatable,
	tonumber = tonumber,
	tostring = tostring,
	type = type,
	typeof = emulatedTypeof,
	unpack = unpack,
	xpcall = xpcall,
	bit32 = bit32,
	buffer = buffer,
	coroutine = coroutine,
	debug = debug,
	math = math,
	os = os,
	string = string,
	table = table,
	utf8 = utf8,
	warn = function(...)
		print("[warn]", ...)
	end,
	game = wrap(game),
	Instance = InstanceLibrary,
	Random = RandomLibrary,
	task = TaskLibrary,
	-- Test introspection of emulated yields.
	__testYields = function()
		return yields
	end,
	CFrame = roblox.CFrame,
	Vector3 = roblox.Vector3,
	NumberRange = roblox.NumberRange,
	Color3 = roblox.Color3,
	Enum = roblox.Enum,
}

local cache: { [any]: any } = {}
local loading: { [any]: boolean } = {}

local function load(target: any, extra: { [string]: any }?): any
	local module = unwrap(target)
	local key = module:GetFullName()
	if cache[key] ~= nil then
		return cache[key]
	end
	if loading[key] then
		error("cyclic require of " .. key)
	end
	if not module:IsA("ModuleScript") then
		error("attempt to require a non-ModuleScript: " .. key)
	end
	loading[key] = true
	local env = setmetatable({}, { __index = baseGlobals })
	env.script = wrap(module)
	env.require = function(target)
		return load(target)
	end
	if extra then
		for k, v in extra do
			env[k] = v
		end
	end
	local chunk = luau.load(module.Source, { debugName = module:GetFullName(), environment = env, injectGlobals = false })
	local value = chunk()
	loading[key] = nil
	cache[key] = value
	return value
end

-- Mini TestEZ -------------------------------------------------------------

type test = { name: string, fn: () -> () }
local tests: { test } = {}
local scope: { string } = {}

local function describe(name: string, fn: () -> ())
	table.insert(scope, name)
	fn()
	table.remove(scope)
end

local function it(name: string, fn: () -> ())
	local full = table.concat(scope, " > ") .. " > " .. name
	table.insert(tests, { name = full, fn = fn })
end

local function fmt(v: any): string
	if type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

local function expect(actual: any)
	local function make(negated: boolean)
		local function check(pass: boolean, message: string)
			if pass == negated then
				error((if negated then "expected NOT: " else "expected: ") .. message, 3)
			end
		end
		local api = {}
		api.equal = function(expected: any)
			check(actual == expected, string.format("%s == %s", fmt(actual), fmt(expected)))
		end
		api.ok = function()
			check(actual ~= nil and actual ~= false, string.format("%s to be ok", fmt(actual)))
		end
		api.a = function(typeName: string)
			check(typeof(actual) == typeName, string.format("%s to be a %s", fmt(actual), typeName))
		end
		api.near = function(expected: number, limit: number?)
			local l = limit or 1e-7
			check(math.abs(actual - expected) <= l, string.format("%s near %s", fmt(actual), fmt(expected)))
		end
		api.throw = function()
			local ok = pcall(actual)
			check(not ok, "function to throw")
		end
		return api
	end
	local positive = make(false)
	local negative = make(true)
	local chain = {}
	chain.to = setmetatable({ be = positive, never = setmetatable({ be = negative }, { __index = negative }) }, {
		__index = positive,
	})
	chain.never = setmetatable({ to = setmetatable({ be = negative }, { __index = negative }) }, {})
	return chain
end

local testGlobals = { describe = describe, it = it, expect = expect }

-- Discover and run --------------------------------------------------------

local specs = {}
for _, descendant in game:GetDescendants() do
	if descendant:IsA("ModuleScript") and string.sub(descendant.Name, -5) == ".spec" then
		table.insert(specs, descendant)
	end
end
table.sort(specs, function(a, b)
	return a:GetFullName() < b:GetFullName()
end)

for _, spec in specs do
	local body = load(spec, testGlobals)
	describe(spec.Name, body)
end

local coverage = if process.env.COVERAGE then {} else nil
baseGlobals._G = { __coverage = coverage }
local passed, failed = 0, 0
for _, t in tests do
	if filter and not string.find(t.name, filter, 1, true) then
		continue
	end
	local ok, err = xpcall(t.fn, function(e)
		return tostring(e) .. "\n" .. debug.traceback()
	end)
	if ok then
		passed += 1
	else
		failed += 1
		print(stdio.color("red") .. "FAIL " .. stdio.color("reset") .. t.name)
		print("    " .. string.gsub(tostring(err), "\n", "\n    "))
	end
end

if coverage then
	local keys = {}
	for k in coverage do
		table.insert(keys, k)
	end
	table.sort(keys)
	for _, k in keys do
		print(k, coverage[k])
	end
end
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	process.exit(1)
end
