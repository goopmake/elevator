--!nonstrict
local f = require(script.Parent.fixtures)
local planner = require(script.Parent.planning)

local function root(floor)
	return floor.nodes[floor.root]
end

local function names(floor, plan)
	local list = {}
	for _, emission in plan.emissions do
		table.insert(list, floor.models[emission.model].name)
	end
	return table.concat(list, ",")
end

local function near(a, b)
	return f.cframeNear(a, b, 1e-3)
end

-- A room with doors facing outwards along +X, -X and +Z.
local function room(name)
	return f.room(name, {
		connections = {
			{ name = "DoorE", cframe = CFrame.new(5, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0) },
			{ name = "DoorW", cframe = CFrame.new(-5, 0, 0) * CFrame.Angles(0, math.pi / 2, 0) },
			{ name = "Vent", cframe = CFrame.new(0, 0, 5) * CFrame.Angles(0, math.pi, 0) },
		},
	})
end

return function()
	describe("each", function()
		it("creates one slot per matching connection, in name order", function()
			local floor = f.compileOk(f.asm("Root", {
				f.asm("Lobby", { room("Room"), f.each("Doors", { f.model("Sign") }, "Door") }),
			}))
			local lobby = floor.nodes[root(floor).children[1].node]
			local each = floor.nodes[lobby.children[2].node]
			expect(#each.slots).to.equal(2)
			expect(each.slots[1].connection).to.equal("DoorE")
			expect(each.slots[2].connection).to.equal("DoorW")
			expect(each.slots[1].node).to.equal(each.slots[2].node)
			expect(each.slots[1].key ~= each.slots[2].key).to.equal(true)
			expect(near(each.slots[1].placement, CFrame.new(5, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0))).to.equal(true)
		end)

		it("mates the child's anchor on every slot", function()
			local hall = f.asm("Hall", { room("HallRoom") }, { attributes = { fb_anchor = "DoorW" } })
			local floor = f.compileOk(f.asm("Root", {
				f.asm("Lobby", { room("Room"), f.each("Doors", { f.optional(hall) }, "Door") }),
			}))
			local lobby = floor.nodes[root(floor).children[1].node]
			local each = floor.nodes[lobby.children[2].node]
			for _, slot in each.slots do
				expect(slot.anchor).to.equal("DoorW")
				local parentDoor = floor.models[1].connections[1]
				for _, c in floor.models[1].connections do
					if c.name == slot.connection then
						parentDoor = c
					end
				end
				local mated = slot.placement * CFrame.new(-5, 0, 0) * CFrame.Angles(0, math.pi / 2, 0)
				expect((mated.Position - parentDoor.offset.Position).Magnitude < 1e-3).to.equal(true)
				expect((mated.LookVector + parentDoor.offset.LookVector).Magnitude < 1e-3).to.equal(true)
			end
		end)

		it("skips connections that are already used", function()
			local floor = f.compileOk(f.asm("Root", {
				f.asm("Lobby", {
					room("Room"),
					f.model("Door", { attributes = { fb_attach = "DoorE" } }),
					f.each("Rest", { f.model("Sign") }, "Door"),
				}),
			}))
			local plan = planner.run(floor, { seed = 1, maxRecursionDepth = 0 })
			expect(names(floor, plan)).to.equal("Room,Door,Sign")
		end)

		it("validates its child and context", function()
			local failure = f.compileErr(f.asm("Root", {
				f.asm("A", { room("RA"), f.each("Two", { f.model("X"), f.model("Y") }) }),
				f.asm("B", { room("RB"), f.each("Kind", { f.try("T") }) }),
				f.asm("C", { room("RC"), f.each("Attached", { f.model("Z", { attributes = { fb_attach = "Vent" } }) }) }),
				f.asm("D", { f.each("NoRoom", { f.model("W") }) }),
			}))
			expect(f.count(failure.errors, "EACH_CHILD_COUNT")).to.equal(1)
			expect(f.count(failure.errors, "EACH_CHILD_KIND")).to.equal(1)
			expect(f.count(failure.errors, "EACH_CHILD_ATTACHED")).to.equal(1)
			expect(f.count(failure.errors, "ATTACH_NO_ROOM")).to.equal(1)
		end)

		it("warns when the filter matches nothing", function()
			local floor = f.compileOk(f.asm("Root", { f.asm("A", { room("R"), f.each("None", { f.model("X") }, "Window") }) }))
			expect(f.count(floor.warnings, "FILTER_MATCHES_NOTHING")).to.equal(1)
		end)

		it("cannot be used through a reference", function()
			local lobby = f.asm("Lobby", { room("Room") })
			local each = f.each("Doors", { f.model("Sign") })
			each.Parent = lobby
			local failure = f.compileErr(f.asm("Root", {
				lobby,
				f.asm("Other", { room("Room2"), f.ref("Borrowed", each) }),
			}))
			expect(f.count(failure.errors, "ATTACH_SCOPE")).to.equal(1)
		end)
	end)

	describe("plugs", function()
		it("seals connections that stay unused", function()
			local floor = f.compileOk(f.asm("Root", {
				f.asm("Lobby", {
					room("Room"),
					f.model("Door", { attributes = { fb_attach = "DoorE" } }),
					f.model("Grate", { tags = { "fb_plug" }, attributes = { fb_filter = "Vent" } }),
					f.model("Wall", { tags = { "fb_plug" } }),
				}),
			}))
			local lobby = floor.nodes[root(floor).children[1].node]
			expect(#lobby.children).to.equal(2)
			expect(#lobby.plugs).to.equal(3)
			local plan = planner.run(floor, { seed = 1, maxRecursionDepth = 0 })
			-- DoorE is used; DoorW gets a wall, Vent gets the grate.
			expect(names(floor, plan)).to.equal("Room,Door,Wall,Grate")
		end)

		it("validates plugs", function()
			local failure = f.compileErr(f.asm("Root", {
				f.asm("NoRoom", { f.model("P1", { tags = { "fb_plug" } }) }),
				f.asm("A", { room("R"), f.try("T", { f.model("P2", { tags = { "fb_plug" } }) }) }),
				f.asm("B", { room("R2"), f.model("P3", { tags = { "fb_plug", "fb_conditional_model" }, overlap = CFrame.identity }) }),
				f.asm("C", { room("R3"), f.model("P4", { tags = { "fb_plug" }, attributes = { fb_attach = "Vent" } }) }),
				f.asm("D", { room("R4"), f.model("NotAPlug", { attributes = { fb_filter = "Door" } }) }),
			}))
			expect(f.count(failure.errors, "PLUG_INVALID")).to.equal(3)
			expect(f.count(failure.errors, "PLUG_NOT_DIRECT_CHILD")).to.equal(1)
			expect(f.count(failure.errors, "ATTRIBUTE_NOT_APPLICABLE")).to.equal(1)
		end)
	end)

	describe("picks", function()
		it("draws a random amount from a NumberRange", function()
			local candidates = {}
			for i = 1, 5 do
				table.insert(candidates, f.model("M" .. i))
			end
			local floor = f.compileOk(f.asm("Root", { f.pick("Some", NumberRange.new(1, 3), candidates, true) }))
			local p = floor.nodes[root(floor).children[1].node]
			expect(p.amountMin).to.equal(1)
			expect(p.amountMax).to.equal(3)
			local seen = {}
			for seed = 1, 60 do
				local amount = #planner.run(floor, { seed = seed, maxRecursionDepth = 0 }).selections[1]
				expect(amount >= 1 and amount <= 3).to.equal(true)
				seen[amount] = true
			end
			expect(seen[1] and seen[2] and seen[3]).to.equal(true)
		end)

		it("checks feasibility against the largest amount", function()
			local failure = f.compileErr(f.asm("Root", {
				f.pick("TooMany", NumberRange.new(1, 4), { f.model("A"), f.model("B") }, true),
				f.pick("Fraction", NumberRange.new(0.5, 2), { f.model("C") }),
			}))
			expect(f.count(failure.errors, "PICK_IMPOSSIBLE")).to.equal(1)
			expect(f.count(failure.errors, "PICK_AMOUNT_INVALID")).to.equal(1)
		end)

		it("keeps trying candidates in fit mode", function()
			local function build(mode)
				local p = f.pick("Choice", 1, {
					f.conditional("Clash", { cframe = CFrame.new(0, 0, 0), attributes = { fb_pick_weight = 5 } }),
					f.conditional("Free", { cframe = CFrame.new(30, 0, 0) }),
				})
				p:SetAttribute("fb_pick_mode", mode)
				return f.compileOk(f.asm("Root", {
					f.optional(f.conditional("Blocker", { cframe = CFrame.identity })),
					f.optional(p),
				}))
			end
			local strict, fit = build("strict"), build("fit")
			local strictFree, fitFree = 0, 0
			for seed = 1, 60 do
				if string.find(names(strict, planner.run(strict, { seed = seed, maxRecursionDepth = 0 })), "Free") then
					strictFree += 1
				end
				if string.find(names(fit, planner.run(fit, { seed = seed, maxRecursionDepth = 0 })), "Free") then
					fitFree += 1
				end
			end
			expect(fitFree).to.equal(60)
			expect(strictFree < 60).to.equal(true)
		end)

		it("validates fb_pick_mode", function()
			local failure = f.compileErr(f.asm("Root", {
				f.node("Configuration", "pick Bad", { attributes = { fb_pick_amount = 1, fb_pick_mode = "greedy" }, children = { f.asm("A") } }),
			}))
			expect(f.count(failure.errors, "PICK_MODE_INVALID")).to.equal(1)
		end)
	end)

	describe("limits", function()
		it("emits a counted definition at most fb_max_count times", function()
			local boss = f.asm("Boss", { f.model("Throne") }, { attributes = { fb_max_count = 1 } })
			local floor = f.compileOk(f.asm("Root", {
				f.folder("L", { boss }),
				f.optional(f.ref("B1", boss)),
				f.optional(f.ref("B2", boss)),
				f.optional(f.ref("B3", boss)),
			}))
			local plan = planner.run(floor, { seed = 1, maxRecursionDepth = 0 })
			expect(names(floor, plan)).to.equal("Throne")
		end)

		it("releases counts when a branch is rolled back", function()
			local boss = f.model("Boss", { attributes = { fb_max_count = 1 } })
			local floor = f.compileOk(f.asm("Root", {
				f.folder("L", { boss }),
				f.try("T", {
					f.asm("Doomed", {
						f.ref("Counted", boss),
						f.conditional("Clash1", { cframe = CFrame.identity }),
						f.conditional("Clash2", { cframe = CFrame.identity }),
					}),
					f.ref("Again", boss),
				}),
			}))
			local plan = planner.run(floor, { seed = 1, maxRecursionDepth = 0 })
			expect(names(floor, plan)).to.equal("Boss")
		end)

		it("limits a recursive reference with fb_max_depth", function()
			local a = f.asm("A", { f.model("Segment") })
			f.optional(f.ref("Again", a, { attributes = { fb_max_depth = 2 } })).Parent = a
			local floor = f.compileOk(f.asm("Root", { f.ref("Start", a) }))
			local plan = planner.run(floor, { seed = 1, maxRecursionDepth = 10 })
			expect(#plan.emissions).to.equal(3)
		end)

		it("discards only the optional child that failed", function()
			local floor = f.compileOk(f.asm("Root", {
				f.optional(f.conditional("Blocker", { cframe = CFrame.identity })),
				f.asm("Room", {
					f.model("Floor"),
					f.optional(f.asm("Decor", { f.model("Rug"), f.conditional("Clash", { cframe = CFrame.identity }) })),
					f.model("Ceiling"),
				}),
			}))
			local plan = planner.run(floor, { seed = 1, maxRecursionDepth = 0 })
			expect(names(floor, plan)).to.equal("Blocker,Floor,Ceiling")
		end)
	end)
end
