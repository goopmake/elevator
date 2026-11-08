--!strict
--[[
	Minimal synchronous signal for communication between plugin modules.
]]

export type signal<T> = {
	connect: (self: signal<T>, listener: (T) -> ()) -> () -> (),
	fire: (self: signal<T>, value: T) -> (),
}

local function new<T>(): signal<T>
	local listeners: { (T) -> () } = {}

	local function connect(_self: signal<T>, listener: (T) -> ()): () -> ()
		table.insert(listeners, listener)
		return function()
			local index = table.find(listeners, listener)
			if index then
				table.remove(listeners, index)
			end
		end
	end

	local function fire(_self: signal<T>, value: T)
		for _, listener in table.clone(listeners) do
			listener(value)
		end
	end

	return {
		connect = connect,
		fire = fire,
	}
end

return table.freeze({
	new = new,
})
