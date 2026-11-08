--!nonstrict
--[[
	Transactional semantics of compiled floors, executed with the test-only
	reference planner (see reference_planner.luau and the execution contract
	in types.luau).
]]
local f = require(script.Parent.fixtures)
local planner = require(script.Parent.planning)

local function names(floor, plan)
	local list = {}
	for _, emission in plan.emissions do
		table.insert(list, floor.models[emission.model].name)
	end
	return table.concat(list, ",")
end

-- Two conditional models at the same place collide; models at different
-- places do not.
local function at(x)
	return { cframe = CFrame.new(x, 0, 0) }
end

return function()
	describe("transactional planning", function()
		it("discards all planned output of a failed assembly", function()
			local floor = f.compileOk(f.asm("Root", {
				f.try("BlockerSlot", { f.conditional("Blocker", at(0)) }),
				f.try("T", {
					f.asm("Room", {
						f.model("Floor"),
						f.conditional("Free", at(10)),
						f.conditional("Clash", at(0)),
					}),
				}),
			}))
			local plan = planner.run(floor, { seed = 1, maxRecursionDepth = 4 })
			expect(plan.status).to.equal("success")
			expect(names(floor, plan)).to.equal("Blocker")
			expect(#plan.volumes).to.equal(1)
		end)

		it("leaves no residue from failed try alternatives", function()
			local floor = f.compileOk(f.asm("Root", {
				f.try("BlockerSlot", { f.conditional("Blocker", at(0)) }),
				f.try("T", {
					f.asm("First", { f.conditional("A", at(20)), f.conditional("Clash", at(0)) }),
					f.asm("Second", { f.conditional("B", at(30)) }),
				}),
			}))
			local plan = planner.run(floor, { seed = 1, maxRecursionDepth = 4 })
			expect(names(floor, plan)).to.equal("Blocker,B")
			-- The volume of A was released, so it no longer blocks anything.
			for _, v in plan.volumes do
				expect(floor.models[v.model].name ~= "A").to.equal(true)
			end
		end)

		it("restores nested checkpoints", function()
			local floor = f.compileOk(f.asm("Root", {
				f.try("BlockerSlot", { f.conditional("Blocker", at(0)) }),
				f.try("Outer", {
					f.asm("Attempt", {
						f.conditional("Kept?", at(40)),
						f.try("Inner", {
							f.conditional("InnerClash", at(0)),
							f.conditional("InnerOk", at(50)),
						}),
						f.conditional("LateClash", at(0)),
					}),
					f.conditional("Fallback", at(40)),
				}),
			}))
			local plan = planner.run(floor, { seed = 1, maxRecursionDepth = 4 })
			-- Kept? and InnerOk were planned, then discarded with the failed
			-- assembly, so Fallback (same place as Kept?) can now be accepted.
			expect(names(floor, plan)).to.equal("Blocker,Fallback")
		end)

		it("keeps accepted reservations consistent", function()
			local floor = f.compileOk(f.asm("Root", {
				f.try("A", { f.conditional("One", at(0)) }),
				f.try("B", { f.conditional("Two", at(0)) }),
				f.try("C", { f.conditional("Three", at(5)) }),
			}))
			local plan = planner.run(floor, { seed = 1, maxRecursionDepth = 4 })
			expect(names(floor, plan)).to.equal("One,Three")
			for i, a in plan.volumes do
				for j, b in plan.volumes do
					if i ~= j then
						expect(planner.boxesOverlap(a, b)).to.equal(false)
					end
				end
			end
		end)

		it("does not fail an assembly containing an exhausted try", function()
			local floor = f.compileOk(f.asm("Root", {
				f.try("BlockerSlot", { f.conditional("Blocker", at(0)) }),
				f.try("Outer", {
					f.asm("Room", {
						f.model("Floor"),
						f.try("Optional", { f.conditional("Clash", at(0)) }),
					}),
				}),
			}))
			local plan = planner.run(floor, { seed = 1, maxRecursionDepth = 4 })
			expect(names(floor, plan)).to.equal("Blocker,Floor")
		end)

		it("bounds recursion with the builder's maximum depth", function()
			local a = f.asm("A", { f.model("Segment") })
			f.try("More", { f.ref("Again", a) }).Parent = a
			local floor = f.compileOk(f.asm("Root", { f.ref("Start", a) }))
			for depth = 0, 5 do
				local plan = planner.run(floor, { seed = 1, maxRecursionDepth = depth })
				expect(plan.status).to.equal("success")
				expect(#plan.emissions).to.equal(depth + 1)
			end
		end)

	end)
end
