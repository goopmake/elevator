--!nonstrict
local builder = require(script.Parent.Parent)
local boxes = require(script.Parent.boxes)
local compiler = require(script.Parent.Parent.Parent.compiler)
local f = require(script.Parent.Parent.Parent.compiler.tests.fixtures)

local function near(a, b)
	return f.cframeNear(a, b, 1e-3)
end

local function plan(floor, options)
	local world = boxes.recorder(options.collides)
	local o = table.clone(options)
	o.collides = nil
	o.collision = world.factory
	return builder.plan(floor, o), world
end

local function corridorFloor()
	local corridor = f.asm("Corridor", {
		f.room("CorridorRoom", {
			connections = {
				{ name = "In", cframe = CFrame.new(0, 0, -5) },
				{ name = "Out", cframe = CFrame.new(0, 0, 5) * CFrame.Angles(0, math.pi, 0) },
			},
		}),
	})
	f.optional(f.ref("Next", corridor, { attributes = { fb_attach = "Out", fb_anchor = "In" } })).Parent = corridor
	return f.compileOk(f.asm("Root", { f.folder("L", { corridor }), f.ref("Start", corridor) }))
end

-- Deep copy of a frozen compiled floor with one edge modified, refrozen.
local function tamper(floor, modify)
	local function copy(value)
		if type(value) ~= "table" then
			return value
		end
		local out = {}
		for k, v in value do
			out[k] = copy(v)
		end
		return out
	end
	local nodes = {}
	for i, n in floor.nodes do
		nodes[i] = copy(n)
	end
	modify(nodes)
	local function freezeDeep(value)
		if type(value) == "table" and not table.isfrozen(value) then
			for _, v in value do
				freezeDeep(v)
			end
			table.freeze(value)
		end
		return value
	end
	return table.freeze({
		formatVersion = floor.formatVersion,
		root = floor.root,
		nodes = freezeDeep(nodes),
		models = floor.models,
		counters = floor.counters,
		warnings = floor.warnings,
	})
end

return function()
	describe("input validation", function()
		local floor = f.compileOk(f.asm("Root", { f.model("M") }))

		it("rejects invalid options", function()
			local cases = {
				{ seed = "x" },
				{ seed = 0 / 0 },
				{ seed = 1, maxRecursionDepth = -1 },
				{ seed = 1, maxRecursionDepth = 1.5 },
				{ seed = 1, origin = Vector3.new() },
				{ seed = 1, collision = 5 },
				{ seed = 1, planningParent = "nope" },
				{ seed = 1, yieldBudget = 0 },
				{ seed = 1, trace = "yes" },
			}
			for _, options in cases do
				local planned = builder.plan(floor, options)
				expect(planned.ok).to.equal(false)
				expect(planned.err.code).to.equal("OPTIONS_INVALID")
			end
			expect(builder.plan(floor, nil).err.code).to.equal("OPTIONS_INVALID")
		end)

		it("rejects floors it does not understand", function()
			expect(builder.plan(nil, { seed = 1 }).err.code).to.equal("FLOOR_INVALID")
			local old = table.freeze({ formatVersion = 1, root = 1, nodes = {}, models = {}, counters = 0, warnings = {} })
			local planned = builder.plan(old, { seed = 1 })
			expect(planned.err.code).to.equal("FLOOR_INVALID")
			expect(string.find(planned.err.message, "Recompile", 1, true)).to.be.ok()
			local unfrozen = table.clone(floor)
			expect(builder.plan(unfrozen, { seed = 1 }).err.code).to.equal("FLOOR_INVALID")
		end)
	end)

	describe("planning", function()
		it("is deterministic and reusable", function()
			local floor = corridorFloor()
			local a = plan(floor, { seed = 3 })
			local b = plan(floor, { seed = 3 })
			expect(#a.val.emissions).to.equal(#b.val.emissions)
			for i, e in a.val.emissions do
				expect(near(e.pivot, b.val.emissions[i].pivot)).to.equal(true)
			end
		end)

		it("uses the default recursion depth", function()
			local planned = plan(corridorFloor(), { seed = 1 })
			expect(#planned.val.emissions).to.equal(builder.DEFAULT_MAX_RECURSION_DEPTH + 1)
		end)

		it("places the floor at the origin", function()
			local origin = CFrame.new(100, 0, 50) * CFrame.Angles(0, 1, 0)
			local planned = plan(corridorFloor(), { seed = 1, maxRecursionDepth = 2, origin = origin })
			local emissions = planned.val.emissions
			expect(near(emissions[1].pivot, origin)).to.equal(true)
			expect(near(emissions[2].pivot, origin * CFrame.new(0, 0, 10))).to.equal(true)
		end)

		it("produces an immutable plan and releases the collision world", function()
			local planned, world = plan(corridorFloor(), { seed = 1 })
			expect(table.isfrozen(planned.val)).to.equal(true)
			expect(table.isfrozen(planned.val.emissions)).to.equal(true)
			expect(table.isfrozen(planned.val.emissions[1])).to.equal(true)
			expect(world.destroyed()).to.equal(true)
		end)

		it("counts handled failures by reason", function()
			local boss = f.model("Boss", { attributes = { fb_max_count = 1 } })
			local floor = f.compileOk(f.asm("Root", {
				f.folder("L", { boss }),
				f.optional(f.ref("B1", boss)),
				f.optional(f.ref("B2", boss)),
				f.optional(f.conditional("A", { cframe = CFrame.identity })),
				f.optional(f.conditional("B", { cframe = CFrame.identity })),
			}))
			local planned = plan(floor, { seed = 1, trace = true })
			local failures = planned.val.stats.failures
			expect(failures.count).to.equal(1)
			expect(failures.overlap).to.equal(1)
			expect(planned.val.counters[1]).to.equal(1)
			expect(#planned.val.trace.failures).to.equal(2)
			expect(planned.val.trace.failures[1].reason).to.equal("count")
		end)

		it("yields when given a budget", function()
			local before = __testYields()
			plan(corridorFloor(), { seed = 1, yieldBudget = 1e-9 })
			expect(__testYields() > before).to.equal(true)
		end)
	end)

	describe("defect detection", function()
		it("refuses to plan a graph whose guarantees are broken", function()
			local floor = f.compileOk(f.asm("Root", {
				f.optional(f.conditional("A", { cframe = CFrame.identity })),
				f.optional(f.conditional("B", { cframe = CFrame.identity })),
			}))
			-- Pretend the compiler had forgotten that B can fail.
			local broken = tamper(floor, function(nodes)
				local edge = nodes[floor.root].children[2]
				edge.optional = false
				edge.mayFail = false
			end)
			local planned = plan(broken, { seed = 1 })
			expect(planned.ok).to.equal(false)
			expect(planned.err.code).to.equal("COMPILER_DEFECT")
		end)

		it("detects an uncontested connection that is already used", function()
			local floor = f.compileOk(f.asm("Root", {
				f.asm("Lobby", {
					f.room("Room", { connections = { { name = "East", cframe = CFrame.identity } } }),
					f.optional(f.model("A", { attributes = { fb_attach = "East" } })),
					f.optional(f.model("B", { attributes = { fb_attach = "East" } })),
				}),
			}))
			local broken = tamper(floor, function(nodes)
				for _, n in nodes do
					for _, e in n.children or {} do
						e.contested = false
					end
				end
			end)
			expect(plan(broken, { seed = 1 }).err.code).to.equal("COMPILER_DEFECT")
		end)
	end)

	describe("commit", function()
		it("spawns every emission at its pivot", function()
			local floor = corridorFloor()
			local planned = plan(floor, { seed = 1, maxRecursionDepth = 2 })
			local parent = Instance.new("Folder")
			local spawned = builder.commit(planned.val, parent, "Level1")
			expect(spawned.Name).to.equal("Level1")
			expect(spawned.Parent).to.equal(parent)
			local children = spawned:GetChildren()
			expect(#children).to.equal(3)
			for i, model in children do
				expect(near(model.PrimaryPart.CFrame, planned.val.emissions[i].pivot)).to.equal(true)
			end
		end)

		it("moves models rigidly", function()
			local m = f.model("Table", { cframe = CFrame.new(10, 0, 0) })
			local leg = Instance.new("Part")
			leg.Name = "Leg"
			leg.CFrame = CFrame.new(12, -1, 0)
			leg.Parent = m
			local floor = f.compileOk(f.asm("Root", { m }))
			local planned = plan(floor, { seed = 1, origin = CFrame.new(0, 5, 0) * CFrame.Angles(0, math.pi / 2, 0) })
			local model = builder.commit(planned.val):GetChildren()[1]
			local relative = model.PrimaryPart.CFrame:ToObjectSpace(model.Leg.CFrame)
			expect(near(relative, CFrame.new(2, -1, 0))).to.equal(true)
		end)

		it("creates independent copies on every commit", function()
			local planned = plan(corridorFloor(), { seed = 1, maxRecursionDepth = 1 })
			local a = builder.commit(planned.val)
			local b = builder.commit(planned.val)
			expect(a ~= b).to.equal(true)
			expect(a:GetChildren()[1] ~= b:GetChildren()[1]).to.equal(true)
		end)

		it("never spawns overlap volumes", function()
			local floor = f.compileOk(f.asm("Root", { f.optional(f.conditional("Lamp")) }))
			local spawned = builder.commit(plan(floor, { seed = 1 }).val)
			expect(spawned:FindFirstChild("overlap", true)).to.equal(nil)
		end)

		it("plans and commits in one step", function()
			local floor = f.compileOk(f.asm("Root", { f.model("M") }))
			local world = boxes.recorder()
			local generated = builder.generate(floor, { seed = 1, collision = world.factory })
			expect(generated.ok).to.equal(true)
			expect(#generated.val:GetChildren()).to.equal(1)
		end)
	end)
end
