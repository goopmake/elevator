--!strict
--[[
	Transactional planning state.

	Everything a planning attempt can change lives in append-only logs:
	planned emissions, accepted overlap volumes (in the collision world),
	consumed connections and counter increments. A checkpoint is the length of
	every log; restoring truncates all of them together, so a failed attempt
	leaves nothing behind.

	Random streams are not part of the state: every node derives its own
	stream from its position (compiler.stream), so rollback never needs to
	rewind randomness.
]]

local compiler = require(script.Parent.Parent.compiler)
local types = require(script.Parent.types)

export type checkpoint = {
	emissions: number,
	volumes: number,
	connections: number,
	counters: number,
}

export type state = {
	world: types.collision_world,
	emissions: { types.emission },
	-- Consumed connections: log of keys and the set of the same keys.
	connectionLog: { string },
	consumed: { [string]: boolean },
	-- Counter increments: log of counter ids and current counts.
	counterLog: { number },
	counts: { number },
	nextScope: number,
}

local function new(world: types.collision_world, counters: number): state
	return {
		world = world,
		emissions = {},
		connectionLog = {},
		consumed = {},
		counterLog = {},
		counts = table.create(counters, 0),
		nextScope = 0,
	}
end

local function checkpoint(s: state): checkpoint
	return {
		emissions = #s.emissions,
		volumes = s.world.size(),
		connections = #s.connectionLog,
		counters = #s.counterLog,
	}
end

local function restore(s: state, cp: checkpoint)
	for i = #s.emissions, cp.emissions + 1, -1 do
		s.emissions[i] = nil
	end
	s.world.truncate(cp.volumes)
	for i = #s.connectionLog, cp.connections + 1, -1 do
		s.consumed[s.connectionLog[i]] = nil
		s.connectionLog[i] = nil
	end
	for i = #s.counterLog, cp.counters + 1, -1 do
		local id = s.counterLog[i]
		s.counts[id] -= 1
		s.counterLog[i] = nil
	end
end

local function newScope(s: state): number
	s.nextScope += 1
	return s.nextScope
end

local function connectionKey(scope: number, name: string): string
	return string.format("%d\0%s", scope, name)
end

local function isConsumed(s: state, scope: number, name: string): boolean
	return s.consumed[connectionKey(scope, name)] == true
end

local function consume(s: state, scope: number, name: string)
	local key = connectionKey(scope, name)
	s.consumed[key] = true
	table.insert(s.connectionLog, key)
end

-- Counts one emission against a counter. False when the limit is reached.
local function count(s: state, counter: compiler.counter_id, limit: number): boolean
	local current = s.counts[counter]
	if current >= limit then
		return false
	end
	s.counts[counter] = current + 1
	table.insert(s.counterLog, counter)
	return true
end

local function emit(s: state, emission: types.emission)
	table.insert(s.emissions, emission)
end

return table.freeze({
	new = new,
	checkpoint = checkpoint,
	restore = restore,
	newScope = newScope,
	isConsumed = isConsumed,
	consume = consume,
	count = count,
	emit = emit,
})
