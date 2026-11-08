--!nonstrict
local f = require(script.Parent.fixtures)
local planner = require(script.Parent.planning)

local function cf(c)
	local parts = {}
	for _, v in { c:GetComponents() } do
		table.insert(parts, string.format("%.4f", v))
	end
	return table.concat(parts, " ")
end

-- A complete, order-preserving textual form of a compiled floor.
local function serialize(floor)
	local lines = { "root " .. floor.root .. " counters " .. floor.counters }
	local function edge(e)
		return string.format(
			"->%d [%s] rec=%s depth=%s opt=%s conn=%s anchor=%s contested=%s fail=%s key=%d from=%s",
			e.node,
			cf(e.placement),
			tostring(e.recursive),
			tostring(e.maxDepth),
			tostring(e.optional),
			tostring(e.connection),
			tostring(e.anchor),
			tostring(e.contested),
			tostring(e.mayFail),
			e.key,
			e.source.path
		)
	end
	for _, n in floor.nodes do
		local head = string.format("%d %s %s %s fail=%s", n.id, n.kind, n.source.path, n.source.label, tostring(n.mayFail))
		local edges = {}
		if n.kind == "assembly" then
			head ..= string.format(" room=%s counter=%s/%s", tostring(n.room), tostring(n.counter), tostring(n.maxCount))
			for _, e in n.children do
				table.insert(edges, edge(e))
			end
			for _, e in n.plugs do
				table.insert(edges, "plug " .. edge(e))
			end
		elseif n.kind == "try" then
			for _, e in n.alternatives do
				table.insert(edges, edge(e))
			end
		elseif n.kind == "each" then
			for _, e in n.slots do
				table.insert(edges, edge(e))
			end
		elseif n.kind == "pick" then
			head ..= string.format(" amount=%d..%d unique=%s mode=%s total=%d", n.amountMin, n.amountMax, tostring(n.unique), n.mode, n.totalWeight)
			for _, c in n.candidates do
				table.insert(edges, string.format("w=%d %s", c.weight, edge(c.edge)))
			end
		else
			head ..= string.format(" model=%d conditional=%s counter=%s/%s", n.model, tostring(n.conditional), tostring(n.counter), tostring(n.maxCount))
		end
		table.insert(lines, head)
		for _, e in edges do
			table.insert(lines, "  " .. e)
		end
	end
	for _, m in floor.models do
		local line = string.format("model %d %s %s", m.id, m.name, m.sourcePath)
		for _, c in m.connections do
			line ..= string.format(" %s[%s]", c.name, cf(c.offset))
		end
		if m.overlap then
			line ..= " overlap[" .. cf(m.overlap.offset) .. "]"
		end
		table.insert(lines, line)
	end
	return table.concat(lines, "\n")
end

local function buildSource()
	local corridor = f.asm("Corridor", {
		f.room("CorridorRoom", {
			cframe = CFrame.new(3, 0, 1),
			connections = {
				{ name = "In", cframe = CFrame.new(0, 0, -5) },
				{ name = "Out", cframe = CFrame.new(0, 0, 5) * CFrame.Angles(0, math.pi, 0) },
			},
		}),
		f.try("Decor", { f.conditional("Plant", { cframe = CFrame.new(4, 0, 2) }), f.model("Rug") }),
		f.model("Wall", { tags = { "fb_plug" } }),
	})
	f.try("More", { f.ref("Next", corridor, { attributes = { fb_attach = "Out", fb_anchor = "In" } }) }).Parent = corridor
	return f.asm("Root", {
		f.folder("Library", { corridor }),
		f.ref("Start", corridor),
		f.try("Rooms", {
			f.pick("Choice", 2, {
				f.asm("A", { f.model("Crate") }, { attributes = { fb_pick_weight = 3 } }),
				f.asm("B", { f.model("Barrel") }),
				f.asm("C", { f.model("Crate2") }, { attributes = { fb_pick_weight = 0 } }),
			}, true),
		}),
	})
end

return function()
	describe("determinism", function()
		it("compiles the same source to the same representation", function()
			local source = buildSource()
			expect(serialize(f.compileOk(source))).to.equal(serialize(f.compileOk(source)))
		end)

		it("compiles equivalent sources to the same representation", function()
			expect(serialize(f.compileOk(buildSource()))).to.equal(serialize(f.compileOk(buildSource())))
		end)

		it("assigns registry ids in a stable order", function()
			local floor = f.compileOk(buildSource())
			local namesInOrder = {}
			for _, m in floor.models do
				table.insert(namesInOrder, m.name)
			end
			expect(table.concat(namesInOrder, ",")).to.equal("CorridorRoom,Wall,Plant,Rug,Crate,Barrel,Crate2")
		end)

		it("keeps the decision tree structure stable", function()
			local floor = f.compileOk(buildSource())
			local r = floor.nodes[floor.root]
			expect(#r.children).to.equal(2)
			expect(floor.nodes[r.children[1].node].source.label).to.equal("Corridor")
			expect(floor.nodes[r.children[2].node].kind).to.equal("try")
		end)

		it("reproduces planning for the same seed", function()
			local floor = f.compileOk(buildSource())
			for seed = 1, 20 do
				local a = planner.run(floor, { seed = seed, maxRecursionDepth = 3 })
				local b = planner.run(floor, { seed = seed, maxRecursionDepth = 3 })
				expect(#a.emissions).to.equal(#b.emissions)
				for i, e in a.emissions do
					expect(e.model).to.equal(b.emissions[i].model)
					expect(cf(e.pivot)).to.equal(cf(b.emissions[i].pivot))
				end
			end
		end)
	end)

	describe("stable random streams", function()
		local function pickedLabels(floor, plan)
			local labels = {}
			for _, emission in plan.emissions do
				table.insert(labels, floor.models[emission.model].name)
			end
			return table.concat(labels, ",")
		end

		local function source(extra)
			local children = {
				f.pick("Left", 1, { f.model("L1"), f.model("L2"), f.model("L3"), f.model("L4") }),
			}
			if extra then
				table.insert(children, f.pick("Middle", 1, { f.model("M1"), f.model("M2") }))
			end
			table.insert(children, f.pick("Right", 1, { f.model("R1"), f.model("R2"), f.model("R3"), f.model("R4") }))
			return f.asm("Root", children)
		end

		it("does not re-roll unrelated nodes when a sibling is added", function()
			local before = f.compileOk(source(false))
			local after = f.compileOk(source(true))
			for seed = 1, 40 do
				local a = pickedLabels(before, planner.run(before, { seed = seed, maxRecursionDepth = 0 }))
				local b = pickedLabels(after, planner.run(after, { seed = seed, maxRecursionDepth = 0 }))
				local aLeft, aRight = string.match(a, "^(L%d),(R%d)$")
				local bLeft, bRight = string.match(b, "^(L%d),M%d,(R%d)$")
				expect(aLeft).to.equal(bLeft)
				expect(aRight).to.equal(bRight)
			end
		end)

		it("gives repeated selections of one candidate their own streams", function()
			local floor = f.compileOk(f.asm("Root", {
				f.pick("Twice", 2, {
					f.asm("Inner", { f.pick("Choice", 1, { f.model("A"), f.model("B"), f.model("C"), f.model("D") }) }),
				}),
			}))
			local differs = false
			for seed = 1, 40 do
				local plan = planner.run(floor, { seed = seed, maxRecursionDepth = 0 })
				if plan.emissions[1].model ~= plan.emissions[2].model then
					differs = true
				end
			end
			expect(differs).to.equal(true)
		end)
	end)

	describe("weighted selection", function()
		local function pickFloor(amount, unique)
			return f.compileOk(f.asm("Root", {
				f.pick("P", amount, {
					f.asm("One", {}, { attributes = { fb_pick_weight = 1 } }),
					f.asm("Three", {}, { attributes = { fb_pick_weight = 3 } }),
					f.asm("Zero", {}, { attributes = { fb_pick_weight = 0 } }),
					f.asm("Six", {}, { attributes = { fb_pick_weight = 6 } }),
				}, unique),
			}))
		end

		it("never selects zero-weight candidates and follows the weights", function()
			local floor = pickFloor(1, false)
			local counts = { 0, 0, 0, 0 }
			for seed = 1, 3000 do
				local plan = planner.run(floor, { seed = seed, maxRecursionDepth = 0 })
				local chosen = plan.selections[1][1]
				counts[chosen] += 1
			end
			expect(counts[3]).to.equal(0)
			expect(counts[1] < counts[2]).to.equal(true)
			expect(counts[2] < counts[4]).to.equal(true)
		end)

		it("never repeats a candidate in a unique selection", function()
			local floor = pickFloor(3, true)
			for seed = 1, 200 do
				local chosen = planner.run(floor, { seed = seed, maxRecursionDepth = 0 }).selections[1]
				expect(#chosen).to.equal(3)
				local seen = {}
				for _, i in chosen do
					expect(seen[i]).to.equal(nil)
					expect(i ~= 3).to.equal(true)
					seen[i] = true
				end
			end
		end)

		it("rejects impossible selections", function()
			local failure = f.compileErr(f.asm("Root", {
				f.pick("TooMany", 3, { f.asm("A"), f.asm("B", {}, { attributes = { fb_pick_weight = 0 } }) }, true),
				f.pick("Nothing", 1, { f.asm("C", {}, { attributes = { fb_pick_weight = 0 } }) }),
				f.pick("Empty", 2, {}),
			}))
			expect(f.count(failure.errors, "PICK_IMPOSSIBLE")).to.equal(3)
		end)

		it("validates pick attributes", function()
			local failure = f.compileErr(f.asm("Root", {
				f.pick("Negative", -1, { f.asm("A") }),
				f.pick("Fraction", 1.5, { f.asm("B") }),
				f.node("Configuration", "pick Missing", { children = { f.asm("C") } }),
				f.node("Configuration", "pick UniqueType", {
					attributes = { fb_pick_amount = 1, fb_pick_unique = "yes" },
					children = { f.asm("D") },
				}),
				f.pick("Weights", 1, {
					f.asm("E", {}, { attributes = { fb_pick_weight = -2 } }),
					f.asm("F", {}, { attributes = { fb_pick_weight = 0.25 } }),
					f.asm("G", {}, { attributes = { fb_pick_weight = "heavy" } }),
					f.asm("H", {}, { attributes = { fb_pick_weight = 0 / 0 } }),
				}),
			}))
			expect(f.count(failure.errors, "PICK_AMOUNT_INVALID")).to.equal(2)
			expect(f.count(failure.errors, "ATTRIBUTE_MISSING")).to.equal(1)
			expect(f.count(failure.errors, "PICK_WEIGHT_INVALID")).to.equal(3)
			expect(f.count(failure.errors, "ATTRIBUTE_TYPE")).to.equal(2)
		end)

		it("allows repeated selection when not unique", function()
			local floor = pickFloor(5, false)
			local repeated = false
			for seed = 1, 50 do
				local seen = {}
				for _, i in planner.run(floor, { seed = seed, maxRecursionDepth = 0 }).selections[1] do
					if seen[i] then
						repeated = true
					end
					seen[i] = true
				end
			end
			expect(repeated).to.equal(true)
		end)
	end)
end
