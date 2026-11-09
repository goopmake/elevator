--!strict
--[[
	Persistent plugin settings.

	Stored with plugin:SetSetting, which keeps JSON-like values per user.
	Everything read back is validated; anything malformed falls back to its
	default, so a corrupted setting can never break the plugin.
]]

export type path = { string }

export type values = {
	enginePath: path,
	autoCompile: boolean,
	autoPreview: boolean,
	ghostSource: boolean,
	lockPreview: boolean,
	showConnections: boolean,
	showOverlaps: boolean,
	showFailures: boolean,
	showProblems: boolean,
	seed: number,
	maxDepth: number,
	offset: { number },
	-- Open root per place key.
	roots: { [string]: path },
	-- Most recently opened roots, newest first, per place key.
	recent: { [string]: { path } },
	-- Panel sections the user has collapsed, by section id.
	collapsed: { [string]: boolean },
}

local KEY = "FloorBuilder.Settings.v1"
local MAX_RECENT = 8

local function defaults(): values
	return {
		enginePath = { "ServerStorage", "modules", "floorgen" },
		autoCompile = true,
		autoPreview = false,
		ghostSource = true,
		lockPreview = true,
		showConnections = true,
		showOverlaps = true,
		showFailures = true,
		showProblems = true,
		seed = 1,
		maxDepth = 8,
		offset = { 0, 0, 0 },
		roots = {},
		recent = {},
		collapsed = {},
	}
end

local function isPath(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local list = value :: { unknown }
	if #list == 0 then
		return false
	end
	for _, segment in list do
		if type(segment) ~= "string" then
			return false
		end
	end
	return true
end

local function readPath(value: unknown): path?
	if not isPath(value) then
		return nil
	end
	local out: path = {}
	for _, segment in value :: { string } do
		table.insert(out, segment)
	end
	return out
end

local function readBoolean(value: unknown, fallback: boolean): boolean
	return if type(value) == "boolean" then value else fallback
end

local function readWhole(value: unknown, fallback: number, minimum: number): number
	if type(value) == "number" and value == value and math.floor(value) == value and value >= minimum then
		return value
	end
	return fallback
end

-- Validates a raw settings table read from storage.
local function sanitize(raw: unknown): values
	local result = defaults()
	if type(raw) ~= "table" then
		return result
	end
	local t = raw :: { [string]: unknown }
	local enginePath = readPath(t.enginePath)
	-- The engine used to live directly in ServerStorage.modules; settings saved
	-- by earlier versions still point there.
	if enginePath and #enginePath == 2 and enginePath[1] == "ServerStorage" and enginePath[2] == "modules" then
		enginePath = nil
	end
	result.enginePath = enginePath or result.enginePath
	result.autoCompile = readBoolean(t.autoCompile, result.autoCompile)
	result.autoPreview = readBoolean(t.autoPreview, result.autoPreview)
	result.ghostSource = readBoolean(t.ghostSource, result.ghostSource)
	result.lockPreview = readBoolean(t.lockPreview, result.lockPreview)
	result.showConnections = readBoolean(t.showConnections, result.showConnections)
	result.showOverlaps = readBoolean(t.showOverlaps, result.showOverlaps)
	result.showFailures = readBoolean(t.showFailures, result.showFailures)
	result.showProblems = readBoolean(t.showProblems, result.showProblems)
	result.seed = readWhole(t.seed, result.seed, -2 ^ 31)
	result.maxDepth = readWhole(t.maxDepth, result.maxDepth, 0)

	local offset = t.offset
	if type(offset) == "table" then
		local o = offset :: { unknown }
		local x, y, z = o[1], o[2], o[3]
		if type(x) == "number" and type(y) == "number" and type(z) == "number" then
			result.offset = { x, y, z }
		end
	end

	local roots = t.roots
	if type(roots) == "table" then
		for key, value in roots :: { [unknown]: unknown } do
			local p = readPath(value)
			if type(key) == "string" and p then
				result.roots[key] = p
			end
		end
	end

	local recent = t.recent
	if type(recent) == "table" then
		for key, list in recent :: { [unknown]: unknown } do
			if type(key) == "string" and type(list) == "table" then
				local paths: { path } = {}
				for _, value in list :: { unknown } do
					local p = readPath(value)
					if p and #paths < MAX_RECENT then
						table.insert(paths, p)
					end
				end
				result.recent[key] = paths
			end
		end
	end

	local collapsed = t.collapsed
	if type(collapsed) == "table" then
		for key, value in collapsed :: { [unknown]: unknown } do
			if type(key) == "string" and value == true then
				result.collapsed[key] = true
			end
		end
	end
	return result
end

local function samePath(a: path, b: path): boolean
	if #a ~= #b then
		return false
	end
	for i, segment in a do
		if b[i] ~= segment then
			return false
		end
	end
	return true
end

-- Puts a path at the front of a recent list (without duplicates).
local function pushRecent(list: { path }, p: path): { path }
	local out: { path } = { p }
	for _, existing in list do
		if not samePath(existing, p) and #out < MAX_RECENT then
			table.insert(out, existing)
		end
	end
	return out
end

export type store = {
	values: values,
	save: () -> (),
}

local function load(plugin: Plugin): store
	local values = sanitize(plugin:GetSetting(KEY))
	return {
		values = values,
		save = function()
			plugin:SetSetting(KEY, values)
		end,
	}
end

return table.freeze({
	load = load,
	sanitize = sanitize,
	defaults = defaults,
	pushRecent = pushRecent,
	samePath = samePath,
	MAX_RECENT = MAX_RECENT,
})
