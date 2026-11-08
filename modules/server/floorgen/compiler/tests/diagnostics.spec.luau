--!nonstrict
local f = require(script.Parent.fixtures)

return function()
	describe("diagnostics", function()
		it("accumulates independent errors", function()
			local children = {}
			for i = 1, 20 do
				table.insert(children, f.node("Configuration", "bad name " .. i))
			end
			local failure = f.compileErr(f.asm("Root", children))
			expect(#failure.errors).to.equal(20)
		end)

		it("reports independent errors from different stages together", function()
			local failure = f.compileErr(f.asm("Root", {
				f.node("Part", "Loose"), -- parsing
				f.ref("Empty", nil), -- resolution
				f.pick("P", 1, { f.asm("A") }, "yes"), -- attributes
				f.model("NoPivot", { noPrimaryPart = true }), -- models
				f.model("Attach", { attributes = { fb_attach = "Door" } }), -- spatial
				f.conditional("Unhandled"), -- failure analysis
			}))
			local codes = f.codes(failure.errors)
			for _, expected in {
				"NODE_INVALID_CHILD_CLASS",
				"REFERENCE_EMPTY",
				"ATTRIBUTE_TYPE",
				"MODEL_NO_PRIMARY_PART",
				"ATTACH_NO_ROOM",
				"FAILURE_UNHANDLED",
			} do
				expect(table.find(codes, expected) ~= nil).to.equal(true)
			end
			expect(#failure.errors).to.equal(6)
		end)

		it("does not cascade from a broken child", function()
			local failure = f.compileErr(f.asm("Root", {
				f.pick("P", 2, { f.asm("Good"), f.ref("Broken", nil) }, true),
			}))
			-- Only the broken reference is reported; the pick is not also
			-- reported as impossible because its candidate list is incomplete.
			expect(#failure.errors).to.equal(1)
			expect(failure.errors[1].code).to.equal("REFERENCE_EMPTY")
		end)

		it("does not cascade from a broken room", function()
			local failure = f.compileErr(f.asm("Root", {
				f.asm("Lobby", {
					f.room("Room", { noPrimaryPart = true }),
					f.model("Lamp", { attributes = { fb_attach = "Door" } }),
					f.try("T", { f.model("Clock", { attributes = { fb_attach = "Wall" } }) }),
				}),
			}))
			expect(#failure.errors).to.equal(1)
			expect(failure.errors[1].code).to.equal("MODEL_NO_PRIMARY_PART")
		end)

		it("does not cascade from a broken anchor model", function()
			local hall = f.asm("Hall", { f.room("HallRoom", { noPrimaryPart = true }) })
			local failure = f.compileErr(f.asm("Root", {
				f.folder("Library", { hall }),
				f.asm("Lobby", {
					f.room("Room", { connections = { { name = "Door", cframe = CFrame.identity } } }),
					f.ref("Hall", hall, { attributes = { fb_attach = "Door", fb_anchor = "Back" } }),
				}),
			}))
			expect(#failure.errors).to.equal(1)
			expect(failure.errors[1].code).to.equal("MODEL_NO_PRIMARY_PART")
		end)

		it("never returns a compiled floor with errors", function()
			local compiled = f.compile(f.asm("Root", { f.conditional("Unhandled"), f.model("Fine") }))
			expect(compiled.ok).to.equal(false)
			expect(compiled.val).to.equal(nil)
			expect(compiled.err.errors).to.be.ok()
		end)

		it("succeeds with warnings only", function()
			local floor = f.compileOk(f.asm("Root", { f.pick("P", 0, { f.asm("A") }) }))
			expect(f.count(floor.warnings, "PICK_AMOUNT_ZERO")).to.equal(1)
		end)

		it("fills every diagnostic field that applies", function()
			local failure = f.compileErr(f.asm("Root", { f.pick("P", -3, { f.asm("A") }) }))
			local d = failure.errors[1]
			expect(d.severity).to.equal("error")
			expect(d.code).to.equal("PICK_AMOUNT_INVALID")
			expect(d.path).to.equal("asm Root.pick P")
			expect(d.attribute).to.equal("fb_pick_amount")
			expect(type(d.message)).to.equal("string")
			expect(d.instance).to.be.ok()
			local compiler = require(script.Parent.Parent)
			local text = compiler.formatDiagnostic(d)
			expect(string.find(text, "PICK_AMOUNT_INVALID", 1, true)).to.be.ok()
			expect(string.find(text, "asm Root.pick P", 1, true)).to.be.ok()
		end)

		it("rejects unknown language attributes and tags but ignores developer data", function()
			local failure = f.compileErr(f.asm("Root", {
				f.asm("A", {}, { attributes = { fb_pick_wieght = 2, Color = "red" }, tags = { "fb_atomic", "Interactable" } }),
			}))
			expect(f.count(failure.errors, "ATTRIBUTE_UNKNOWN")).to.equal(1)
			expect(f.count(failure.errors, "TAG_UNKNOWN")).to.equal(1)
			expect(#failure.errors).to.equal(2)
		end)
	end)
end
