--!nonstrict
--[[
	Randomised soundness check of the failure-path proof.

	Generates random source programs (assemblies, atomic assemblies, try, pick,
	plain and conditional models, references with cycles). Every program that
	compiles is executed with the reference planner under adversarial
	collision oracles and several recursion limits. The compiler's guarantee
	is that the root never fails, whatever the runtime outcomes are.
]]
local f = require(script.Parent.fixtures)
local planner = require(script.Parent.planning)

local function lcg(seed)
	local state = seed % 2147483646 + 1
	return function(n)
		state = (state * 48271) % 2147483647
		return 1 + state % n
	end
end

local DOORS = { "D1", "D2", "D3" }

-- Generates mostly valid programs: attachments and each nodes only appear
-- where a room is in scope, and failures are often (not always) handled.
local function generate(seed)
	local roll = lcg(seed)
	local counter = 0
	local function name()
		counter += 1
		return "n" .. counter
	end
	local function chance(n)
		return roll(n) == 1
	end
	local function door()
		return DOORS[roll(#DOORS)]
	end
	local function maybeOptional(instance)
		if chance(2) then
			instance:AddTag("fb_optional")
		end
		return instance
	end
	local function doorRoom()
		local connections = {}
		for i, d in DOORS do
			table.insert(connections, { name = d, cframe = CFrame.new(i * 6, 0, 0) * CFrame.Angles(0, i, 0) })
		end
		return f.room(name(), { connections = connections, cframe = CFrame.new(roll(5), 0, 0) })
	end

	local library = {}
	for _ = 1, roll(3) do
		local entry = f.asm(name(), { doorRoom() })
		if chance(3) then
			entry:SetAttribute("fb_max_count", roll(3) - 1)
		end
		table.insert(library, entry)
	end

	local gen
	local function modelNode(hasRoom)
		local m
		if chance(2) then
			m = f.conditional(name(), { cframe = CFrame.new(roll(4) * 3, 0, 0) })
		else
			m = f.model(name(), { cframe = CFrame.new(roll(4), 0, 0) })
		end
		if chance(5) then
			m:SetAttribute("fb_max_count", roll(3) - 1)
		end
		if hasRoom and chance(2) then
			m:SetAttribute("fb_attach", door())
		end
		return maybeOptional(m)
	end

	local function asmNode(depth)
		local children = {}
		local hasRoom = chance(2)
		if hasRoom then
			table.insert(children, doorRoom())
		end
		for _ = 1, roll(4) - 1 do
			table.insert(children, gen(depth + 1, hasRoom))
		end
		if hasRoom and chance(3) then
			table.insert(children, f.model(name(), { tags = { "fb_plug" } }))
		end
		local a = f.asm(name(), children)
		if chance(6) then
			a:SetAttribute("fb_max_count", roll(2))
		end
		return maybeOptional(a)
	end

	local function candidate(depth, hasRoom)
		local c = if chance(2) then modelNode(hasRoom) else asmNode(depth + 1)
		c:SetAttribute("fb_pick_weight", roll(3) - 1)
		return c
	end

	function gen(depth, hasRoom)
		local choice = if depth > 4 then roll(2) else roll(10)
		if choice == 1 or choice == 2 then
			return modelNode(hasRoom)
		elseif choice == 3 then
			return asmNode(depth)
		elseif choice == 4 or choice == 5 then
			local alternatives = {}
			for _ = 1, roll(3) - 1 do
				table.insert(alternatives, gen(depth + 1, hasRoom))
			end
			return maybeOptional(f.try(name(), alternatives))
		elseif choice == 6 or choice == 7 then
			local candidates = {}
			for _ = 1, roll(3) do
				table.insert(candidates, candidate(depth, hasRoom))
			end
			local low = roll(3) - 1
			local amount = if chance(2) then low else NumberRange.new(low, low + roll(2) - 1)
			local p = f.pick(name(), amount, candidates, chance(2))
			if chance(2) then
				p:SetAttribute("fb_pick_mode", "fit")
			end
			return maybeOptional(p)
		elseif choice == 8 and hasRoom then
			local body = if chance(2) then modelNode(false) else asmNode(depth + 1)
			body:SetAttribute("fb_attach", nil)
			return maybeOptional(f.each(name(), { body }, if chance(2) then "D" else "D2"))
		else
			local options = { attributes = {} }
			if hasRoom and chance(2) then
				options.attributes.fb_attach = door()
				if chance(2) then
					options.attributes.fb_anchor = door()
				end
			end
			if chance(3) then
				options.attributes.fb_max_depth = roll(3) - 1
			end
			return maybeOptional(f.ref(name(), library[roll(#library)], options))
		end
	end

	for _, entry in library do
		for _ = 1, roll(3) do
			gen(3, true).Parent = entry
		end
	end

	local rootChildren = { f.folder("Library", library) }
	for _ = 1, roll(4) do
		table.insert(rootChildren, gen(1, false))
	end
	return f.asm("Root", rootChildren)
end

local function oracles(seed)
	local roll = lcg(seed * 7 + 3)
	return {
		planner.boxesOverlap,
		function()
			return true
		end,
		function()
			return false
		end,
		function()
			return roll(2) == 1
		end,
	}
end

return function()
	describe("soundness of the failure proof", function()
		it("never lets a failure escape the root of a compiled program", function()
			local compiled, rejected = 0, 0
			for seed = 1, 400 do
				local result = f.compile(generate(seed))
				if result.ok then
					compiled += 1
					if _G.__coverage then
						local cov = _G.__coverage
						for _, n in result.val.nodes do
							cov[n.kind] = (cov[n.kind] or 0) + 1
							if n.counter then cov.counted = (cov.counted or 0) + 1 end
							if n.kind == "pick" and n.mode == "fit" then cov.fit = (cov.fit or 0) + 1 end
							if n.kind == "pick" and n.amountMin ~= n.amountMax then cov.ranged = (cov.ranged or 0) + 1 end
							if n.kind == "assembly" and #n.plugs > 0 then cov.plugs = (cov.plugs or 0) + 1 end
							for _, e in n.children or n.alternatives or n.slots or {} do
								if e.contested then cov.contested = (cov.contested or 0) + 1 end
								if e.optional then cov.optional = (cov.optional or 0) + 1 end
								if e.recursive then cov.recursive = (cov.recursive or 0) + 1 end
								if e.maxDepth then cov.maxDepth = (cov.maxDepth or 0) + 1 end
								if e.connection then cov.attach = (cov.attach or 0) + 1 end
							end
						end
					end
					for _, collides in oracles(seed) do
						for depth = 0, 3 do
							local plan = planner.run(result.val, {
								seed = seed,
								maxRecursionDepth = depth,
								collides = collides,
							})
							expect(plan.status).to.equal("success")
						end
					end
					-- Accepted volumes never overlap under the geometric oracle,
					-- and planning is reproducible.
					local plan = planner.run(result.val, { seed = seed, maxRecursionDepth = 3 })
					local again = planner.run(result.val, { seed = seed, maxRecursionDepth = 3 })
					expect(#plan.emissions).to.equal(#again.emissions)
					for i, e in plan.emissions do
						expect(e.model).to.equal(again.emissions[i].model)
					end
					-- Counters never exceed their limits.
					for _, n in result.val.nodes do
						if n.kind ~= "try" and n.kind ~= "pick" and n.kind ~= "each" and n.counter then
							expect((plan.counts[n.counter] or 0) <= n.maxCount).to.equal(true)
						end
					end
					for i, a in plan.volumes do
						for j, b in plan.volumes do
							if i < j then
								expect(planner.boxesOverlap(a, b)).to.equal(false)
							end
						end
					end
				else
					rejected += 1
					expect(#result.err.errors > 0).to.equal(true)
					for _, d in result.err.errors do
						expect(d.code ~= "INTERNAL_INVARIANT").to.equal(true)
					end
				end
			end
			if _G.__coverage then
				_G.__coverage.compiled = compiled
				_G.__coverage.rejected = rejected
			end
			-- Make sure the sample exercises both outcomes.
			expect(compiled > 50).to.equal(true)
			expect(rejected > 50).to.equal(true)
		end)
	end)
end
