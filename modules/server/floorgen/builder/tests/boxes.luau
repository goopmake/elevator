--!strict
--[[
	TEST-ONLY collision world.

	Volumes collide when an injected predicate says so. The default predicate
	is an axis-aligned box test on the volume's centre and size, which is only
	adequate for test fixtures (the real builder uses WorldModel geometry).
	The factory remembers the volumes of the last world it created so tests
	can inspect them after planning.
]]

local builder = require(script.Parent.Parent)
local compiler = require(script.Parent.Parent.Parent.compiler)

export type volume = { cframe: CFrame, size: Vector3, model: number }
export type predicate = (a: volume, b: volume) -> boolean

local function boxesOverlap(a: volume, b: volume): boolean
	local d = a.cframe.Position - b.cframe.Position
	local s = (a.size + b.size) / 2
	return math.abs(d.X) < s.X and math.abs(d.Y) < s.Y and math.abs(d.Z) < s.Z
end

export type recorder = {
	factory: builder.collision_factory,
	-- Accepted volumes of the most recent world, as they were when it was destroyed.
	volumes: () -> { volume },
	destroyed: () -> boolean,
}

local function recorder(collides: predicate?): recorder
	local predicate = collides or boxesOverlap
	local last: { volume } = {}
	local wasDestroyed = false

	local function factory(_context: builder.collision_context): builder.collision_world
		local volumes: { volume } = {}
		last = volumes
		wasDestroyed = false
		return table.freeze({
			tryAccept = function(entry: compiler.model_entry, cframe: CFrame): boolean
				local overlap = entry.overlap
				if overlap == nil then
					return true
				end
				local candidate: volume = { cframe = cframe, size = overlap.size, model = entry.id }
				for _, accepted in volumes do
					if predicate(candidate, accepted) then
						return false
					end
				end
				table.insert(volumes, candidate)
				return true
			end,
			size = function(): number
				return #volumes
			end,
			truncate = function(keep: number)
				for i = #volumes, keep + 1, -1 do
					volumes[i] = nil
				end
			end,
			destroy = function()
				wasDestroyed = true
			end,
		})
	end

	return {
		factory = factory,
		volumes = function()
			return last
		end,
		destroyed = function()
			return wasDestroyed
		end,
	}
end

return table.freeze({
	recorder = recorder,
	boxesOverlap = boxesOverlap,
})
