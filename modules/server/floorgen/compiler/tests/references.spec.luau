--!nonstrict
local f = require(script.Parent.fixtures)

local function root(floor)
	return floor.nodes[floor.root]
end

local function child(floor, n, i)
	local list = n.children or n.alternatives
	return floor.nodes[list[i].node], list[i]
end

return function()
	describe("reference targets", function()
		it("references a model directly", function()
			local crate = f.model("Crate")
			local floor = f.compileOk(f.asm("Root", { f.folder("Assets", { crate }), f.ref("Crate", crate) }))
			local n, e = child(floor, root(floor), 1)
			expect(n.kind).to.equal("model")
			expect(e.source.className).to.equal("ObjectValue")
			expect(e.source.label).to.equal("Crate")
		end)

		it("references nodes of every kind", function()
			local library = f.folder("Library", {
				f.asm("A", { f.model("M") }),
				f.try("T", { f.conditional("C") }),
				f.pick("P", 1, { f.asm("Only") }),
			})
			local source = f.asm("Root", {
				library,
				f.ref("A", library:FindFirstChild("asm A")),
				f.ref("T", library:FindFirstChild("try T")),
				f.ref("P", library:FindFirstChild("pick P")),
			})
			local floor = f.compileOk(source)
			expect(child(floor, root(floor), 1).kind).to.equal("assembly")
			expect(child(floor, root(floor), 2).kind).to.equal("try")
			expect(child(floor, root(floor), 3).kind).to.equal("pick")
		end)

		it("resolves assets inside nested Folders without interpreting the Folder", function()
			local hidden = f.asm("Hidden", { f.model("Inside") })
			local source = f.asm("Root", {
				f.folder("Outer", { f.folder("Inner", { hidden, f.node("Part", "Junk") }) }),
				f.ref("Hidden", hidden),
			})
			local floor = f.compileOk(source)
			expect(#root(floor).children).to.equal(1)
			expect(child(floor, root(floor), 1).source.label).to.equal("Hidden")
		end)

		it("resolves targets outside the root hierarchy", function()
			local elsewhere = f.asm("Elsewhere", { f.model("Thing") })
			local floor = f.compileOk(f.asm("Root", { f.ref("Out", elsewhere) }))
			expect(child(floor, root(floor), 1).source.label).to.equal("Elsewhere")
		end)

		it("rejects invalid targets", function()
			local other = f.ref("Other", f.model("M"))
			local failure = f.compileErr(f.asm("Root", {
				f.ref("Empty", nil),
				f.ref("Chain", other),
				f.ref("Part", f.node("Part", "P")),
				f.ref("Folder", f.folder("F")),
				f.ref("BadConfig", f.node("Configuration", "settings")),
			}))
			expect(f.count(failure.errors, "REFERENCE_EMPTY")).to.equal(1)
			expect(f.count(failure.errors, "REFERENCE_CHAIN")).to.equal(1)
			expect(f.count(failure.errors, "REFERENCE_UNSUPPORTED_TARGET")).to.equal(2)
			expect(f.count(failure.errors, "REFERENCE_TARGET_INVALID")).to.equal(1)
			for _, d in failure.errors do
				expect(d.attribute).to.equal("Value")
			end
		end)

		it("reports errors inside a referenced target once", function()
			local broken = f.asm("Broken", { f.node("Part", "Loose") })
			local failure = f.compileErr(f.asm("Root", { f.ref("One", broken), f.ref("Two", broken) }))
			expect(f.count(failure.errors, "NODE_INVALID_CHILD_CLASS")).to.equal(1)
		end)
	end)

	describe("overrides", function()
		it("inherits the target configuration when there are no overrides", function()
			local p = f.pick("P", 2, { f.asm("A"), f.asm("B") }, true)
			local floor = f.compileOk(f.asm("Root", { f.folder("L", { p }), f.ref("P", p) }))
			local n = child(floor, root(floor), 1)
			expect(n.amountMin).to.equal(2)
			expect(n.unique).to.equal(true)
		end)

		it("ignores non-language attributes on references", function()
			local p = f.pick("P", 2, { f.asm("A"), f.asm("B") }, true)
			local floor = f.compileOk(f.asm("Root", {
				f.folder("L", { p }),
				f.ref("P", p, { attributes = { Note = "developer data" }, tags = { "SomeOtherSystem" } }),
			}))
			expect(child(floor, root(floor), 1).amountMin).to.equal(2)
		end)

		it("layers use-site keys without overriding behaviour", function()
			local hall = f.asm("Hall", { f.room("HallRoom") }, { attributes = { fb_max_count = 3 } })
			local lobbyRoom = f.room("LobbyRoom", { connections = { { name = "East", cframe = CFrame.new(5, 0, 0) } } })
			local floor = f.compileOk(f.asm("Root", {
				f.folder("L", { hall }),
				f.asm("Lobby", {
					lobbyRoom,
					f.optional(f.ref("Hall", hall, { attributes = { fb_attach = "East" } })),
				}),
			}))
			local lobby = child(floor, root(floor), 1)
			local hallNode, edge = child(floor, lobby, 2)
			expect(hallNode.maxCount).to.equal(3) -- behaviour inherited
			expect(edge.connection).to.equal("East") -- use-site applied
			expect(edge.optional).to.equal(true)
			expect(f.count(floor.warnings, "OVERRIDE_REMOVES_KEYS")).to.equal(0)
		end)

		it("requires a complete behaviour override", function()
			local p = f.pick("P", 2, { f.asm("A"), f.asm("B") }, true)
			-- Overriding only fb_pick_unique drops the required fb_pick_amount.
			local failure = f.compileErr(f.asm("Root", {
				f.folder("L", { p }),
				f.ref("P", p, { attributes = { fb_pick_unique = false } }),
			}))
			local d = f.find(failure.errors, "ATTRIBUTE_MISSING")
			expect(d).to.be.ok()
			expect(d.attribute).to.equal("fb_pick_amount")
			expect(d.path).to.equal("asm Root.ref P")
			expect(f.count(failure.warnings, "OVERRIDE_REMOVES_KEYS")).to.equal(1)
		end)

		it("applies a behaviour override and leaves the target untouched", function()
			local p = f.pick("P", 2, { f.asm("A"), f.asm("B") }, true)
			local floor = f.compileOk(f.asm("Root", {
				f.folder("L", { p }),
				f.ref("Original", p),
				f.ref("Overridden", p, { attributes = { fb_pick_amount = 5, fb_pick_unique = false } }),
			}))
			local original = child(floor, root(floor), 1)
			local overridden = child(floor, root(floor), 2)
			expect(original.amountMax).to.equal(2)
			expect(original.unique).to.equal(true)
			expect(overridden.amountMax).to.equal(5)
			expect(overridden.unique).to.equal(false)
			expect(original.candidates[1].edge.node).to.equal(overridden.candidates[1].edge.node)
			expect(p:GetAttribute("fb_pick_amount")).to.equal(2)
			expect(p:GetAttribute("fb_pick_unique")).to.equal(true)
		end)

		it("removes behaviour tags with fb_override", function()
			local lamp = f.conditional("Lamp")
			local floor = f.compileOk(f.asm("Root", {
				f.folder("L", { lamp }),
				f.ref("Lamp", lamp, { tags = { "fb_override" } }),
			}))
			expect(child(floor, root(floor), 1).conditional).to.equal(false)
			expect(f.count(floor.warnings, "OVERRIDE_REMOVES_KEYS")).to.equal(1)
			expect(lamp:HasTag("fb_conditional_model")).to.equal(true)
		end)

		it("keeps behaviour tags without fb_override", function()
			local lamp = f.conditional("Lamp")
			local failure = f.compileErr(f.asm("Root", {
				f.folder("L", { lamp }),
				f.ref("Lamp", lamp, { tags = { "fb_room" } }),
			}))
			expect(f.count(failure.errors, "FAILURE_UNHANDLED")).to.equal(1)
		end)

		it("only allows fb_override on references", function()
			local failure = f.compileErr(f.asm("Root", { f.model("M", { tags = { "fb_override" } }) }))
			expect(f.count(failure.errors, "TAG_NOT_APPLICABLE")).to.equal(1)
		end)

		it("cannot bypass target validation", function()
			local plain = f.model("Plain")
			local failure = f.compileErr(f.asm("Root", {
				f.folder("L", { plain }),
				f.try("T", { f.ref("Plain", plain, { tags = { "fb_conditional_model" } }) }),
			}))
			expect(f.count(failure.errors, "MODEL_OVERLAP_MISSING")).to.equal(1)
		end)

		it("validates override formats", function()
			local p = f.pick("P", 1, { f.asm("A") })
			local failure = f.compileErr(f.asm("Root", {
				f.folder("L", { p }),
				f.ref("Bad", p, { attributes = { fb_pick_amount = "three", fb_typo = 1 }, tags = { "fb_room" } }),
			}))
			expect(f.count(failure.errors, "ATTRIBUTE_TYPE")).to.equal(1)
			expect(f.count(failure.errors, "ATTRIBUTE_UNKNOWN")).to.equal(1)
			expect(f.count(failure.errors, "TAG_NOT_APPLICABLE")).to.equal(1)
		end)

		it("gives each reference an independent configuration", function()
			local a = f.asm("A", { f.model("M") })
			local floor = f.compileOk(f.asm("Root", {
				f.folder("L", { a }),
				f.ref("Plain1", a),
				f.optional(f.ref("Counted", a, { attributes = { fb_max_count = 1 } })),
				f.ref("Plain2", a),
			}))
			local r = root(floor)
			local n1, n2, n3 = child(floor, r, 1), child(floor, r, 2), child(floor, r, 3)
			expect(n1.maxCount).to.equal(nil)
			expect(n2.maxCount).to.equal(1)
			expect(n1).to.equal(n3)
			expect(n1 ~= n2).to.equal(true)
			expect(a:GetAttribute("fb_max_count")).to.equal(nil)
		end)
	end)

	describe("recursion", function()
		it("supports direct recursion", function()
			local a = f.asm("A", { f.model("Segment") })
			f.try("More", { f.ref("Again", a) }).Parent = a
			local floor = f.compileOk(f.asm("Root", { f.ref("Start", a) }))
			local start = child(floor, root(floor), 1)
			local more = child(floor, start, 2)
			local again, edge = child(floor, more, 1)
			expect(again).to.equal(start)
			expect(edge.recursive).to.equal(true)
			expect(edge.mayFail).to.equal(true)
			-- The entry reference is not on a cycle.
			expect(root(floor).children[1].recursive).to.equal(false)
		end)

		it("supports mutual recursion", function()
			local a = f.asm("A", { f.model("MA") })
			local b = f.asm("B", { f.model("MB") })
			f.try("ToB", { f.ref("B", b) }).Parent = a
			f.try("ToA", { f.ref("A", a) }).Parent = b
			local floor = f.compileOk(f.asm("Root", { f.folder("L", { a, b }), f.ref("Start", a) }))
			local recursive = 0
			for _, n in floor.nodes do
				for _, e in n.children or n.alternatives or {} do
					if e.recursive then
						recursive += 1
					end
				end
			end
			expect(recursive).to.equal(2)
		end)

		it("supports recursion that passes through the root", function()
			local r = f.asm("Root", { f.model("M") })
			f.try("Again", { f.ref("Root", r) }).Parent = r
			local floor = f.compileOk(r)
			local again = child(floor, root(floor), 2)
			expect(again.alternatives[1].node).to.equal(floor.root)
			expect(again.alternatives[1].recursive).to.equal(true)
		end)

		it("rejects recursion whose depth failure is unhandled", function()
			local a = f.asm("A", { f.model("Segment") })
			f.ref("Again", a).Parent = a
			local failure = f.compileErr(f.asm("Root", { f.ref("Start", a) }))
			local d = f.find(failure.errors, "FAILURE_UNHANDLED")
			expect(d).to.be.ok()
			expect(d.path).to.equal("asm A.ref Again")
		end)

		it("applies per-reference recursion limits", function()
			local a = f.asm("A", { f.model("Segment") })
			f.optional(f.ref("Again", a, { attributes = { fb_max_depth = 2 } })).Parent = a
			local floor = f.compileOk(f.asm("Root", { f.ref("Start", a) }))
			local start = child(floor, root(floor), 1)
			local _, edge = child(floor, start, 2)
			expect(edge.maxDepth).to.equal(2)
			expect(edge.recursive).to.equal(true)
		end)

		it("warns about fb_max_depth on references that are not recursive", function()
			local a = f.asm("A", { f.model("Segment") })
			local floor = f.compileOk(f.asm("Root", { f.folder("L", { a }), f.ref("Once", a, { attributes = { fb_max_depth = 2 } }) }))
			expect(f.count(floor.warnings, "KEY_NO_EFFECT")).to.equal(1)
		end)

		it("does not inline recursive graphs", function()
			local a = f.asm("A", { f.model("Segment") })
			f.try("More", { f.ref("Again", a), f.ref("Again2", a) }).Parent = a
			local floor = f.compileOk(f.asm("Root", { f.ref("Start", a) }))
			expect(#floor.nodes).to.equal(4) -- root, A, try More, model Segment
		end)
	end)
end
