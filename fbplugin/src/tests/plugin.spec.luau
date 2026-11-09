--!nonstrict
local ServerStorage = game:GetService("ServerStorage")

local compiler = require(ServerStorage.modules.floorgen.compiler)
local f = require(ServerStorage.modules.floorgen.compiler.tests.fixtures)
local format = require(script.Parent.Parent.format)
local roots = require(script.Parent.Parent.roots)
local settings = require(script.Parent.Parent.settings)

local function sample()
	local hall = f.asm("Hall", { f.model("HallModel") })
	local source = f.asm("Root", {
		f.folder("Library", { hall }),
		f.optional(f.conditional("Lamp")),
		f.try("T", { f.asm("Deep", { f.asm("Deeper", { f.model("Leaf") }) }) }),
		f.pick("P", 1, { f.asm("A"), f.asm("B") }),
		f.ref("Hall", hall),
	})
	return compiler.analyze(source), source, hall
end

return function()
	describe("format", function()
		it("formats keys without the language prefix", function()
			expect(format.keyText({ name = "fb_optional" })).to.equal("optional")
			expect(format.keyText({ name = "fb_pick_amount", value = "2" })).to.equal("pick_amount=2")
		end)

		it("describes rows", function()
			local a = sample()
			local lamp = a.root.children[1]
			expect(format.rowText(lamp)).to.equal("[model] Lamp  {conditional_model, optional}")
			local ref = a.root.children[4]
			expect(format.rowText(ref)).to.equal("[ref] Hall  → asm Hall")
			local badges = format.badges(lamp, true)
			expect(badges[1].text).to.equal("may fail · handled")
			expect(badges[1].tone).to.equal("handled")
		end)

		it("shows problems as badges and colours", function()
			local a = compiler.analyze(f.asm("Root", { f.conditional("Bad"), f.optional(f.model("Plain")) }))
			local bad = a.root.children[1]
			expect(format.rowTone(bad)).to.equal("error")
			expect(format.badges(bad, false)[1].text).to.equal("1 error")
			expect(format.badges(bad, false)[2].text).to.equal("may fail")
			local plain = a.root.children[2]
			expect(format.rowTone(plain)).to.equal("warning")
			expect(format.subtreeHasErrors(a.root)).to.equal(true)
		end)

		it("flattens the outline with expansion state", function()
			local a, _, hall = sample()
			-- Auto-expand two levels: Root and its children are visible, "Deep"
			-- is visible as a child of T but not expanded.
			local rows = format.flatten(a, {}, 2)
			local labels = {}
			for _, row in rows do
				table.insert(labels, if row.node then row.node.label else "#")
			end
			expect(table.concat(labels, ",")).to.equal("Root,Lamp,T,Deep,P,A,B,Hall,#,Hall,HallModel")

			local deep = a.root.children[2].children[1]
			local expanded = { [deep.instance] = true, [hall] = false }
			rows = format.flatten(a, expanded, 2)
			labels = {}
			for _, row in rows do
				table.insert(labels, if row.node then row.node.label else "#")
			end
			expect(table.concat(labels, ",")).to.equal("Root,Lamp,T,Deep,Deeper,P,A,B,Hall,#,Hall")
		end)

		it("finds nodes and their ancestry", function()
			local a, source = sample()
			local leaf = source:FindFirstChild("try T"):FindFirstChild("asm Deep"):FindFirstChild("asm Deeper"):FindFirstChild("Leaf")
			local trail = format.ancestry(a, leaf)
			expect(#trail).to.equal(5)
			expect(trail[1]).to.equal(source)
			expect(trail[5]).to.equal(leaf)
			expect(format.findNode(a, leaf).label).to.equal("Leaf")
			expect(format.findNode(a, Instance.new("Part"))).to.equal(nil)
		end)

		it("summarises analyses", function()
			local a = sample()
			local text, tone = format.summary(a)
			expect(string.find(text, "OK", 1, true)).to.be.ok()
			expect(string.find(text, "12 nodes", 1, true)).to.be.ok()
			expect(tone).to.equal("normal")
			local failed = compiler.analyze(f.asm("Root", { f.conditional("Bad") }))
			local failedText, failedTone = format.summary(failed)
			expect(string.find(failedText, "1 error", 1, true)).to.be.ok()
			expect(failedTone).to.equal("error")
		end)

		it("explains a node in detail", function()
			local a = compiler.analyze(f.asm("Root", { f.conditional("Bad") }))
			local text = format.details(a.root.children[1])
			expect(string.find(text, "FAILURE_UNHANDLED", 1, true)).to.be.ok()
			expect(string.find(text, "Hint:", 1, true)).to.be.ok()
			expect(string.find(text, "Path: Root", 1, true) or string.find(text, "Path: asm Root", 1, true)).to.be.ok()
		end)
	end)

	describe("settings", function()
		it("falls back to defaults for malformed values", function()
			local values = settings.sanitize({
				seed = "x",
				maxDepth = -3,
				autoCompile = "yes",
				enginePath = { 1, 2 },
				offset = { 1, "a", 3 },
				roots = { good = { "Workspace", "asm A" }, bad = "nope" },
			})
			local d = settings.defaults()
			expect(values.seed).to.equal(d.seed)
			expect(values.maxDepth).to.equal(d.maxDepth)
			expect(values.autoCompile).to.equal(d.autoCompile)
			expect(values.enginePath[1]).to.equal("ServerStorage")
			expect(values.offset[2]).to.equal(0)
			expect(values.roots.good[2]).to.equal("asm A")
			expect(values.roots.bad).to.equal(nil)
			expect(settings.sanitize(nil).seed).to.equal(d.seed)
		end)

		it("keeps valid values", function()
			local values = settings.sanitize({ seed = 42, maxDepth = 3, ghostSource = false, offset = { 1, 2, 3 } })
			expect(values.seed).to.equal(42)
			expect(values.maxDepth).to.equal(3)
			expect(values.ghostSource).to.equal(false)
			expect(values.offset[3]).to.equal(3)
		end)

		it("keeps only valid collapsed sections", function()
			local values = settings.sanitize({ collapsed = { tree = true, edit = "yes", view = false, [1] = true } })
			expect(values.collapsed.tree).to.equal(true)
			expect(values.collapsed.edit).to.equal(nil)
			expect(values.collapsed.view).to.equal(nil)
			expect(next(settings.sanitize({ collapsed = "nope" }).collapsed)).to.equal(nil)
		end)

		it("keeps recent roots unique and bounded", function()
			local list = {}
			for i = 1, 12 do
				list = settings.pushRecent(list, { "Workspace", "asm " .. i })
			end
			list = settings.pushRecent(list, { "Workspace", "asm 5" })
			expect(#list).to.equal(settings.MAX_RECENT)
			expect(list[1][2]).to.equal("asm 5")
			local count = 0
			for _, p in list do
				if p[2] == "asm 5" then
					count += 1
				end
			end
			expect(count).to.equal(1)
		end)
	end)

	describe("roots", function()
		it("round-trips paths, including names with dots", function()
			local folder = f.folder("Floors.v2")
			local root = f.asm("Main.Level")
			root.Parent = folder
			folder.Parent = game:GetService("Workspace")
			local p = roots.pathOf(root)
			expect(roots.describe(p)).to.equal("Workspace / Floors.v2 / asm Main.Level")
			expect(roots.resolve(p)).to.equal(root)
			expect(roots.pathOf(Instance.new("Folder"))).to.equal(nil)
			folder:Destroy()
		end)

		it("discovers top-level assemblies only", function()
			local library = f.folder("Library", { f.asm("InFolder") })
			local top = f.asm("Top", { f.asm("Nested"), f.try("T", { f.asm("AlsoNested") }) })
			local holder = f.folder("RootsTest", { top, library })
			holder.Parent = game:GetService("Workspace")
			local found = roots.discover(roots.topLevelAssembly(compiler.identify))
			local names = {}
			for _, candidate in found do
				if candidate.instance:IsDescendantOf(holder) then
					table.insert(names, candidate.instance.Name)
				end
			end
			table.sort(names)
			expect(table.concat(names, ",")).to.equal("asm InFolder,asm Top")
			holder:Destroy()
		end)
	end)
end
