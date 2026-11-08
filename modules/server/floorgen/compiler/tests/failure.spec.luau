--!nonstrict
local f = require(script.Parent.fixtures)

local function root(floor)
	return floor.nodes[floor.root]
end

local function unhandled(failure)
	return f.count(failure.errors, "FAILURE_UNHANDLED")
end

local function doorRoom(name, doors)
	local connections = {}
	for i, door in doors do
		table.insert(connections, { name = door, cframe = CFrame.new(i * 10, 0, 0) })
	end
	return f.room(name, { connections = connections })
end

return function()
	describe("failure analysis", function()
		it("rejects an unhandled conditional model", function()
			local failure = f.compileErr(f.asm("Root", { f.conditional("Lamp") }))
			expect(unhandled(failure)).to.equal(1)
			local d = f.find(failure.errors, "FAILURE_UNHANDLED")
			expect(d.path).to.equal("asm Root.Lamp")
			expect(string.find(d.message, "asm Root", 1, true)).to.be.ok()
			expect(d.hint).to.be.ok()
		end)

		it("accepts a conditional model caught by try", function()
			local floor = f.compileOk(f.asm("Root", { f.try("T", { f.conditional("Lamp") }) }))
			local t = floor.nodes[root(floor).children[1].node]
			expect(t.mayFail).to.equal(false)
			expect(t.alternatives[1].mayFail).to.equal(true)
			expect(root(floor).mayFail).to.equal(false)
		end)

		it("accepts a conditional model marked optional", function()
			local floor = f.compileOk(f.asm("Root", { f.optional(f.conditional("Lamp")) }))
			local edge = root(floor).children[1]
			expect(edge.optional).to.equal(true)
			expect(edge.mayFail).to.equal(false)
			expect(floor.nodes[edge.node].mayFail).to.equal(true)
		end)

		it("propagates through assemblies, which fail as a whole", function()
			local failure = f.compileErr(f.asm("Root", {
				f.asm("Room", { f.model("Floor"), f.conditional("Lamp") }),
			}))
			expect(unhandled(failure)).to.equal(1)

			local floor = f.compileOk(f.asm("Root", {
				f.optional(f.asm("Room", { f.model("Floor"), f.conditional("Lamp") })),
			}))
			local room = floor.nodes[root(floor).children[1].node]
			expect(room.mayFail).to.equal(true)
		end)

		it("does not fail an assembly whose children handle their failures", function()
			local floor = f.compileOk(f.asm("Root", {
				f.asm("Room", { f.model("Floor"), f.optional(f.conditional("Lamp")), f.try("T", { f.conditional("Clock") }) }),
			}))
			expect(floor.nodes[root(floor).children[1].node].mayFail).to.equal(false)
		end)

		it("propagates through nested assemblies to an ancestor handler", function()
			local failure = f.compileErr(f.asm("Root", {
				f.asm("A", { f.asm("B", { f.conditional("Lamp") }) }),
			}))
			expect(unhandled(failure)).to.equal(1)
			f.compileOk(f.asm("Root", {
				f.try("T", { f.asm("A", { f.asm("B", { f.conditional("Lamp") }) }) }),
			}))
		end)

		it("handles failures in nested try nodes", function()
			f.compileOk(f.asm("Root", {
				f.try("Outer", {
					f.asm("First", { f.conditional("A"), f.try("Inner", { f.conditional("B") }) }),
					f.try("Fallback", { f.conditional("C") }),
				}),
			}))
		end)

		it("propagates pick failures", function()
			local failure = f.compileErr(f.asm("Root", {
				f.pick("P", 1, { f.asm("A", { f.conditional("Lamp") }), f.asm("B") }),
			}))
			expect(unhandled(failure)).to.equal(1)
			local floor = f.compileOk(f.asm("Root", {
				f.try("T", { f.pick("P", 1, { f.asm("A", { f.conditional("Lamp") }), f.asm("B") }) }),
			}))
			local t = floor.nodes[root(floor).children[1].node]
			expect(floor.nodes[t.alternatives[1].node].mayFail).to.equal(true)
		end)

		it("ignores candidates that can never be selected", function()
			local floor = f.compileOk(f.asm("Root", {
				f.pick("P", 1, {
					f.asm("Never", { f.conditional("Lamp") }, { attributes = { fb_pick_weight = 0 } }),
					f.asm("Safe"),
				}),
				f.pick("None", 0, { f.asm("Risky", { f.conditional("Lamp2") }) }),
			}))
			expect(root(floor).mayFail).to.equal(false)
		end)

		it("handles recursion failures with try or fb_optional", function()
			local a = f.asm("A", { f.model("Segment") })
			f.try("More", { f.ref("Again", a) }).Parent = a
			f.compileOk(f.asm("Root", { f.ref("Start", a) }))

			local b = f.asm("B", { f.model("Segment") })
			f.optional(f.ref("Again", b)).Parent = b
			f.compileOk(f.asm("Root", { f.ref("Start", b) }))
		end)

		it("treats counted nodes as failure sources", function()
			local boss = f.asm("Boss", { f.model("Throne") }, { attributes = { fb_max_count = 1 } })
			local failure = f.compileErr(f.asm("Root", { boss }))
			local d = f.find(failure.errors, "FAILURE_UNHANDLED")
			expect(string.find(d.message, "fb_max_count", 1, true)).to.be.ok()

			local floor = f.compileOk(f.asm("Root", {
				f.folder("Library", { boss }),
				f.optional(f.ref("Boss1", boss)),
				f.optional(f.ref("Boss2", boss)),
			}))
			local first = floor.nodes[root(floor).children[1].node]
			local second = floor.nodes[root(floor).children[2].node]
			expect(first.counter).to.equal(1)
			expect(first).to.equal(second)
			expect(floor.counters).to.equal(1)
		end)

		it("shares one counter across specialisations of a definition", function()
			local boss = f.model("Boss", { attributes = { fb_max_count = 2 }, overlap = CFrame.identity })
			local floor = f.compileOk(f.asm("Root", {
				f.folder("Library", { boss }),
				f.optional(f.ref("Plain", boss)),
				f.optional(f.ref("Conditional", boss, { tags = { "fb_conditional_model" }, attributes = { fb_max_count = 2 } })),
			}))
			local a = floor.nodes[root(floor).children[1].node]
			local b = floor.nodes[root(floor).children[2].node]
			expect(a ~= b).to.equal(true)
			expect(a.counter).to.equal(b.counter)
		end)

		it("detects connections that may be used twice", function()
			local failure = f.compileErr(f.asm("Root", {
				f.asm("Lobby", {
					doorRoom("Room", { "East" }),
					f.model("Sign", { attributes = { fb_attach = "East" } }),
					f.model("Lamp", { attributes = { fb_attach = "East" } }),
				}),
			}))
			expect(unhandled(failure)).to.equal(2)
			local d = f.find(failure.errors, "FAILURE_UNHANDLED")
			expect(string.find(d.message, "East", 1, true)).to.be.ok()
		end)

		it("detects conflicts between sequential users of a connection", function()
			local failure = f.compileErr(f.asm("Root", {
				f.asm("Lobby", {
					doorRoom("Room", { "East" }),
					f.try("Choice", {
						f.model("A", { attributes = { fb_attach = "East" } }),
						f.model("B", { attributes = { fb_attach = "East" } }),
					}),
					f.pick("One", 1, { f.model("C", { attributes = { fb_attach = "East" } }) }),
				}),
			}))
			-- A and B exclude each other, but each may run before C. The uses
			-- inside the try are handled by it; C's is not.
			expect(unhandled(failure)).to.equal(1)
			expect(f.find(failure.errors, "FAILURE_UNHANDLED").path).to.equal("asm Root.asm Lobby.pick One.C")
		end)

		it("accepts exclusive connection uses", function()
			local floor = f.compileOk(f.asm("Root", {
				f.asm("Lobby", {
					doorRoom("Room", { "East", "West" }),
					f.try("Choice", {
						f.model("A", { attributes = { fb_attach = "East" } }),
						f.model("B", { attributes = { fb_attach = "East" } }),
					}),
					f.pick("One", 1, {
						f.model("C", { attributes = { fb_attach = "West" } }),
						f.model("D", { attributes = { fb_attach = "West" } }),
					}, true),
				}),
			}))
			for _, n in floor.nodes do
				for _, e in n.children or n.alternatives or {} do
					expect(e.contested).to.equal(false)
				end
			end
		end)

		it("marks repeated pick candidates as contested", function()
			local failure = f.compileErr(f.asm("Root", {
				f.asm("Lobby", {
					doorRoom("Room", { "East" }),
					f.pick("Many", 2, { f.model("C", { attributes = { fb_attach = "East" } }) }),
				}),
			}))
			expect(unhandled(failure)).to.equal(1)
		end)

		it("treats a connection used to enter an assembly as taken inside it", function()
			local hall = f.asm("Hall", {
				doorRoom("HallRoom", { "In", "Out" }),
				f.model("Sign", { attributes = { fb_attach = "In" } }),
			})
			local failure = f.compileErr(f.asm("Root", {
				f.folder("L", { hall }),
				f.asm("Lobby", {
					doorRoom("LobbyRoom", { "East" }),
					f.ref("Hall", hall, { attributes = { fb_attach = "East", fb_anchor = "In" } }),
				}),
			}))
			local d = f.find(failure.errors, "FAILURE_UNHANDLED")
			expect(d).to.be.ok()
			expect(d.path).to.equal("asm Root.L.asm Hall.Sign")
		end)

		it("reports every escaping failure source", function()
			local failure = f.compileErr(f.asm("Root", {
				f.conditional("One"),
				f.asm("Group", { f.conditional("Two") }),
				f.try("Handled", { f.conditional("Three") }),
				f.optional(f.conditional("Four")),
				f.pick("P", 1, { f.asm("Choice", { f.conditional("Five") }) }),
			}))
			expect(unhandled(failure)).to.equal(3)
		end)

		it("warns about the removed atomic tag", function()
			local floor = f.compileOk(f.asm("Root", { f.asm("Room", { f.model("M") }, { tags = { "fb_atomic_assembly" } }) }))
			expect(f.count(floor.warnings, "TAG_REMOVED")).to.equal(1)
		end)

		it("warns about ineffective fb_optional", function()
			local floor = f.compileOk(f.asm("Root", { f.optional(f.model("Plain")) }))
			expect(f.count(floor.warnings, "KEY_NO_EFFECT")).to.equal(1)
		end)

		it("applies root rules", function()
			expect(f.compileErr(f.asm("Root", {}, { attributes = { fb_max_count = 1 } })).errors[1].code).to.equal("ROOT_COUNTED")
			local a = f.asm("Real", { f.model("M") })
			local floor = f.compileOk(f.ref("Entry", a))
			expect(root(floor).kind).to.equal("assembly")
			local failure = f.compileErr(f.ref("Entry", a, { attributes = { fb_max_count = 3 } }))
			expect(failure.errors[1].code).to.equal("ROOT_COUNTED")
		end)
	end)
end
