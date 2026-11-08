--!nonstrict
local f = require(script.Parent.fixtures)

local function root(floor)
	return floor.nodes[floor.root]
end

return function()
	describe("model validation", function()
		it("requires a PrimaryPart", function()
			local failure = f.compileErr(f.asm("Root", { f.model("NoPivot", { noPrimaryPart = true }) }))
			local d = f.find(failure.errors, "MODEL_NO_PRIMARY_PART")
			expect(d).to.be.ok()
			expect(d.attribute).to.equal("PrimaryPart")
			expect(d.path).to.equal("asm Root.NoPivot")
		end)

		it("requires an overlap part on conditional models", function()
			local m = f.model("Lamp", { tags = { "fb_conditional_model" } })
			local failure = f.compileErr(f.asm("Root", { f.try("T", { m }) }))
			expect(f.count(failure.errors, "MODEL_OVERLAP_MISSING")).to.equal(1)
		end)

		it("rejects ambiguous overlap parts", function()
			local m = f.conditional("Lamp")
			local extra = Instance.new("Part")
			extra.Name = "overlap"
			extra.Parent = m
			local failure = f.compileErr(f.asm("Root", { f.try("T", { m }) }))
			expect(f.count(failure.errors, "MODEL_OVERLAP_AMBIGUOUS")).to.equal(1)
		end)

		it("rejects an overlap part that is the PrimaryPart", function()
			local m = f.model("Lamp", { tags = { "fb_conditional_model" } })
			m.PrimaryPart.Name = "overlap"
			local failure = f.compileErr(f.asm("Root", { f.try("T", { m }) }))
			expect(f.count(failure.errors, "MODEL_OVERLAP_IS_PRIMARY_PART")).to.equal(1)
		end)

		it("accepts a valid overlap part with arbitrary size and rotation", function()
			local offset = CFrame.new(1, 2, 3) * CFrame.Angles(0.3, 0.7, 0.1)
			local m = f.conditional("Lamp", {
				cframe = CFrame.new(10, 0, 0),
				overlap = offset,
				overlapSize = Vector3.new(7, 0.5, 3),
			})
			local floor = f.compileOk(f.asm("Root", { f.try("T", { m }) }))
			expect(#floor.models).to.equal(1)
			local overlap = floor.models[1].overlap
			expect(overlap).to.be.ok()
			expect(f.cframeNear(overlap.offset, offset)).to.equal(true)
			expect(overlap.size).to.equal(Vector3.new(7, 0.5, 3))
		end)

		it("does not require overlap parts on non-conditional models", function()
			local floor = f.compileOk(f.asm("Root", { f.model("Plain") }))
			expect(floor.models[1].overlap).to.equal(nil)
			expect(floor.nodes[root(floor).children[1].node].mayFail).to.equal(false)
		end)

		it("warns when an overlap part is never used", function()
			local m = f.model("Plain", { overlap = CFrame.identity })
			local floor = f.compileOk(f.asm("Root", { m }))
			expect(f.count(floor.warnings, "MODEL_OVERLAP_UNUSED")).to.equal(1)
		end)

		it("validates connection attachments", function()
			local m = f.room("Room", {
				connections = {
					{ name = "Door", cframe = CFrame.new(0, 0, -5) },
					{ name = "Door", cframe = CFrame.new(0, 0, 5) },
				},
			})
			local failure = f.compileErr(f.asm("Root", { m }))
			expect(f.count(failure.errors, "CONNECTION_DUPLICATE_NAME")).to.equal(1)
		end)

		it("rejects connection attachments that are not on a BasePart", function()
			local m = f.room("Room")
			local bone = Instance.new("Attachment")
			bone.Name = "Floating"
			bone:AddTag("fb_connection")
			bone.Parent = m
			local failure = f.compileErr(f.asm("Root", { m }))
			expect(f.count(failure.errors, "CONNECTION_INVALID_PARENT")).to.equal(1)
		end)

		it("warns about language nodes hidden inside models and ignores them", function()
			local m = f.model("Box")
			f.try("Hidden", { f.conditional("Unhandled") }).Parent = m
			local floor = f.compileOk(f.asm("Root", { m }))
			expect(f.count(floor.warnings, "MODEL_CONTAINS_NODES")).to.equal(1)
			expect(#floor.nodes).to.equal(2)
		end)
	end)

	describe("model registry", function()
		it("deduplicates models used by several nodes", function()
			local shared = f.model("Shared")
			local source = f.asm("Root", {
				f.folder("Assets", { shared }),
				f.ref("One", shared),
				f.ref("Two", shared),
				f.try("T", { f.ref("Three", shared, { tags = { "fb_conditional_model" } }) }),
			})
			local overlap = Instance.new("Part")
			overlap.Name = "overlap"
			overlap.Parent = shared
			local floor = f.compileOk(source)
			expect(#floor.models).to.equal(1)
			local r = root(floor)
			-- Two plain uses share one node; the conditional override is its own node.
			expect(r.children[1].node).to.equal(r.children[2].node)
			local plain = floor.nodes[r.children[1].node]
			local t = floor.nodes[r.children[3].node]
			local conditional = floor.nodes[t.alternatives[1].node]
			expect(plain.model).to.equal(1)
			expect(conditional.model).to.equal(1)
			expect(plain.conditional).to.equal(false)
			expect(conditional.conditional).to.equal(true)
		end)

		it("gives every emission its own copy", function()
			local floor = f.compileOk(f.asm("Root", { f.model("Crate") }))
			local entry = floor.models[1]
			local a = entry.instantiate()
			local b = entry.instantiate()
			expect(a ~= b).to.equal(true)
			expect(a.PrimaryPart ~= b.PrimaryPart).to.equal(true)
			expect(a.Parent).to.equal(nil)
		end)

		it("excludes the overlap part from spawned templates", function()
			local floor = f.compileOk(f.asm("Root", { f.try("T", { f.conditional("Lamp") }) }))
			local spawned = floor.models[1].instantiate()
			expect(spawned:FindFirstChild("overlap")).to.equal(nil)
			local volume = floor.models[1].overlap.instantiate()
			expect(volume.Name).to.equal("overlap")
		end)

		it("isolates compiled models from the source", function()
			local crate = f.conditional("Crate", { cframe = CFrame.new(1, 2, 3) })
			local source = f.asm("Root", { f.try("T", { crate }) })
			local floor = f.compileOk(source)

			-- Compilation did not mutate the source.
			expect(crate:FindFirstChild("overlap")).to.be.ok()
			expect(crate.Base.CFrame).to.equal(CFrame.new(1, 2, 3))

			-- Later source edits do not affect the compiled floor.
			local base = crate.Base
			base.Name = "Renamed"
			base.Size = Vector3.new(50, 50, 50)
			crate:FindFirstChild("overlap"):Destroy()
			Instance.new("Part", crate).Name = "Added"
			local spawned = floor.models[1].instantiate()
			expect(spawned:FindFirstChild("Base")).to.be.ok()
			expect(spawned:FindFirstChild("Added")).to.equal(nil)
			expect(spawned.Base.Size).to.equal(Vector3.new(4, 1, 4))
			expect(floor.models[1].overlap).to.be.ok()
		end)

		it("does not expose mutable compiled data", function()
			local floor = f.compileOk(f.asm("Root", { f.model("Crate") }))
			expect(table.isfrozen(floor)).to.equal(true)
			expect(table.isfrozen(floor.nodes)).to.equal(true)
			expect(table.isfrozen(floor.models)).to.equal(true)
			expect(table.isfrozen(floor.models[1])).to.equal(true)
			expect(table.isfrozen(root(floor))).to.equal(true)
			expect(table.isfrozen(root(floor).children)).to.equal(true)
			expect(table.isfrozen(root(floor).children[1])).to.equal(true)
			expect(function()
				root(floor).children[1].node = 5
			end).to.throw()
		end)
	end)
end
