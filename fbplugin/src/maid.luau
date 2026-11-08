--!strict
--[[
	Cleanup bag. Everything the plugin creates or connects is given to a maid
	so that plugin.Unloading (which must not yield) can release it all.
]]

export type task = RBXScriptConnection | Instance | () -> ()

export type maid = {
	give: (self: maid, item: task) -> (),
	clean: (self: maid) -> (),
	tasks: { task },
}

local function give(self: maid, item: task)
	table.insert(self.tasks, item)
end

local function clean(self: maid)
	local tasks = self.tasks
	self.tasks = {}
	for i = #tasks, 1, -1 do
		local item = tasks[i]
		if typeof(item) == "RBXScriptConnection" then
			item:Disconnect()
		elseif typeof(item) == "Instance" then
			item:Destroy()
		elseif type(item) == "function" then
			item()
		end
	end
end

local function new(): maid
	return {
		give = give,
		clean = clean,
		tasks = {},
	}
end

return table.freeze({
	new = new,
})
