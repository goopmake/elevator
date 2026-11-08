--!nonstrict
local compiler = require(script.Parent.Parent)
local f = require(script.Parent.fixtures)

local function find(node, label)
	if node.label == label then
		return node
	end
	for _, child in node.children do
		local found = find(child, label)
		if found then
			return found
		end
	end
	return nil
end

return function()
	describe("analyze", function()
		it("outlines a valid source with analysis results", function()
			local hall = f.asm("Hall", { f.model("HallModel") })
			local source = f.asm("Root", {
				f.folder("Library", { hall }),
				f.optional(f.conditional("Lamp")),
				f.try("T", { f.conditional("Clock") }),
				f.pick("P", 1, { f.asm("A"), f.asm("B") }),
				f.ref("Hall", hall),
			})
			local analysis = compiler.analyze(source)
			expect(analysis.result.ok).to.equal(true)
			expect(type(analysis.elapsed)).to.equal("number")
			local root = analysis.root
			expect(root.kind).to.equal("assembly")
			expect(root.label).to.equal("Root")
			-- The Folder is not part of the outline.
			expect(#root.children).to.equal(4)

			local lamp = find(root, "Lamp")
			expect(lamp.kind).to.equal("model")
			expect(lamp.mayFail).to.equal(true)
			expect(lamp.handled).to.equal(true)
			expect(lamp.compiled).to.equal(true)
			expect(lamp.keys[1].name).to.equal("fb_conditional_model")

			local clock = find(root, "Clock")
			expect(clock.mayFail).to.equal(true)
			expect(clock.handled).to.equal(false)
			expect(find(root, "T").mayFail).to.equal(false)

			local pick = find(root, "P")
			expect(pick.kind).to.equal("pick")
			expect(pick.keys[1].name).to.equal("fb_pick_amount")
			expect(pick.keys[1].value).to.equal("1")

			local ref = root.children[4]
			expect(ref.kind).to.equal("reference")
			expect(ref.target).to.equal(hall)
			expect(ref.targetKind).to.equal("assembly")

			-- The referenced library definition is listed separately.
			expect(#analysis.definitions).to.equal(1)
			expect(analysis.definitions[1].instance).to.equal(hall)
			expect(analysis.definitions[1].children[1].label).to.equal("HallModel")
		end)

		it("outlines failed compilations with diagnostics on their nodes", function()
			local source = f.asm("Root", {
				f.conditional("Unhandled"),
				f.node("Part", "Loose"),
				f.pick("Bad", -1, { f.asm("A") }),
			})
			local analysis = compiler.analyze(source)
			expect(analysis.result.ok).to.equal(false)
			local root = analysis.root
			local unhandled = find(root, "Unhandled")
			expect(#unhandled.diagnostics).to.equal(1)
			expect(unhandled.diagnostics[1].code).to.equal("FAILURE_UNHANDLED")
			local loose = find(root, "Loose")
			expect(loose.kind).to.equal("invalid")
			expect(loose.diagnostics[1].code).to.equal("NODE_INVALID_CHILD_CLASS")
			expect(find(root, "Bad").diagnostics[1].code).to.equal("PICK_AMOUNT_INVALID")
			expect(#analysis.diagnostics).to.equal(3)
		end)

		it("marks recursion and contested connections", function()
			local a = f.asm("A", {
				f.room("Room", { connections = { { name = "East", cframe = CFrame.identity } } }),
				f.optional(f.model("Sign", { attributes = { fb_attach = "East" } })),
				f.optional(f.model("Lamp", { attributes = { fb_attach = "East" } })),
			})
			f.optional(f.ref("Again", a)).Parent = a
			local analysis = compiler.analyze(f.asm("Root", { f.folder("L", { a }), f.ref("Start", a) }))
			expect(analysis.result.ok).to.equal(true)
			local def = analysis.definitions[1]
			expect(find(def, "Again").recursive).to.equal(true)
			expect(find(def, "Sign").contested).to.equal(true)
			expect(find(def, "Room").contested).to.equal(false)
		end)

		it("handles a non-Instance root", function()
			local analysis = compiler.analyze("nope")
			expect(analysis.root).to.equal(nil)
			expect(analysis.diagnostics[1].code).to.equal("ROOT_INVALID")
		end)
	end)
end
