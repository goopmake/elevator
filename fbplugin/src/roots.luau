--!strict
--[[
	Roots, like folders in VS Code: the plugin works on one opened root
	assembly at a time, remembered per place.

	Roots are stored as paths of names from `game` (names may contain dots,
	so paths are arrays, not strings).
]]

export type path = { string }

-- Services searched for candidate roots.
local SEARCHED_SERVICES = { "Workspace", "ServerStorage", "ReplicatedStorage", "ServerScriptService", "Lighting" }
local MAX_CANDIDATES = 200

local function pathOf(instance: Instance): path?
	local names: path = {}
	local current: Instance? = instance
	while current and current ~= game do
		table.insert(names, 1, current.Name)
		current = current.Parent
	end
	if current ~= game then
		-- Not in the DataModel.
		return nil
	end
	return names
end

local function resolve(p: path): Instance?
	local current: Instance = game
	for _, name in p do
		local nextInstance = current:FindFirstChild(name)
		if nextInstance == nil then
			return nil
		end
		current = nextInstance
	end
	return current
end

local function describe(p: path): string
	return table.concat(p, " / ")
end

-- Identifies the open place for per-place settings.
local function placeKey(): string
	if game.PlaceId ~= 0 then
		return "place:" .. tostring(game.PlaceId)
	end
	return "name:" .. game.Name
end

export type candidate = {
	instance: Instance,
	path: path,
}

--[[
	Finds assemblies that could be opened as roots: assembly Configurations
	(named with the assembly prefix) whose parent is not a language container,
	plus references to such assemblies. `isTopLevelAssembly` comes from the
	loaded compiler so naming rules are not duplicated here.
]]
local function discover(isTopLevelAssembly: (Instance) -> boolean): { candidate }
	local found: { candidate } = {}
	for _, serviceName in SEARCHED_SERVICES do
		local service = game:FindFirstChild(serviceName)
		if service == nil then
			continue
		end
		for _, descendant in service:GetDescendants() do
			if #found >= MAX_CANDIDATES then
				break
			end
			if isTopLevelAssembly(descendant) then
				local p = pathOf(descendant)
				if p then
					table.insert(found, { instance = descendant, path = p })
				end
			end
		end
	end
	table.sort(found, function(a, b)
		return describe(a.path) < describe(b.path)
	end)
	return found
end

-- Kinds of Instances as reported by compiler.identify.
export type identify = (instance: Instance) -> string?

local function isContainerKind(kind: string?): boolean
	return kind == "assembly" or kind == "try" or kind == "pick" or kind == "each"
end

-- An assembly whose parent is not a language container: something that can
-- be opened as a root.
local function topLevelAssembly(identify: identify): (Instance) -> boolean
	return function(instance: Instance): boolean
		if instance.ClassName ~= "Configuration" or identify(instance) ~= "assembly" then
			return false
		end
		local parent = instance.Parent
		return parent ~= nil and not isContainerKind(identify(parent))
	end
end

return table.freeze({
	topLevelAssembly = topLevelAssembly,
	pathOf = pathOf,
	resolve = resolve,
	describe = describe,
	placeKey = placeKey,
	discover = discover,
	MAX_CANDIDATES = MAX_CANDIDATES,
})
