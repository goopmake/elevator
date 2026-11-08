--!nonstrict
local f = require(script.Parent.fixtures)

local function root(n)
	return n.nodes[n.root]
end

return function()
	describe("node identification", function()
		it("parses every node type", function()
			local library = f.folder("Library", {
				f.asm("Target", { f.model("Crate") }),
			})
			local source = f.asm("Root", {
				f.model("Floor"),
				f.try("Optional", { f.conditional("Lamp") }),
				f.pick("Rooms", 1, { f.asm("A", { f.model("ModelA") }), f.asm("B") }),
				f.ref("Target", library:FindFirstChild("asm Target")),
			})
			library.Parent = source
			local floor = f.compileOk(source)
			local r = root(floor)
			expect(r.kind).to.equal("assembly")
			expect(#r.children).to.equal(4)
			expect(floor.nodes[r.children[1].node].kind).to.equal("model")
			expect(floor.nodes[r.children[2].node].kind).to.equal("try")
			expect(floor.nodes[r.children[3].node].kind).to.equal("pick")
			expect(floor.nodes[r.children[4].node].kind).to.equal("assembly")
			expect(floor.nodes[r.children[4].node].source.label).to.equal("Target")
		end)

		it("treats the label as free text", function()
			local floor = f.compileOk(f.asm("  weird label: with (anything)!", { f.try("") }))
			expect(root(floor).source.label).to.equal("  weird label: with (anything)!")
		end)

		it("rejects unknown and malformed prefixes", function()
			local failure = f.compileErr(f.asm("Root", {
				f.node("Configuration", "assembly X"),
				f.node("Configuration", "Asm X"),
				f.node("Configuration", "try"),
				f.node("Configuration", "trying X"),
			}))
			expect(f.count(failure.errors, "NODE_UNKNOWN_PREFIX")).to.equal(4)
			for _, d in failure.errors do
				expect(d.hint).to.be.ok()
				expect(d.instance).to.be.ok()
			end
		end)

		it("rejects nodes with the wrong Instance class", function()
			local failure = f.compileErr(f.asm("Root", {
				f.node("ObjectValue", "asm X"),
				f.node("Configuration", "ref X"),
			}))
			expect(f.count(failure.errors, "NODE_WRONG_CLASS")).to.equal(2)
		end)

		it("rejects Instances that are not part of the language", function()
			local failure = f.compileErr(f.asm("Root", {
				f.node("Part", "Loose"),
				f.node("Script", "Code"),
				f.node("StringValue", "ref text"),
			}))
			expect(f.count(failure.errors, "NODE_INVALID_CHILD_CLASS")).to.equal(3)
			expect(f.count(failure.errors, "NODE_UNKNOWN_PREFIX")).to.equal(0)
		end)

		it("rejects a root that is not an assembly", function()
			expect(f.compileErr(f.try("Root")).errors[1].code).to.equal("ROOT_NOT_ASSEMBLY")
			expect(f.compileErr(f.pick("Root", 0)).errors[1].code).to.equal("ROOT_NOT_ASSEMBLY")
			expect(f.compileErr(f.model("Root")).errors[1].code).to.equal("ROOT_NOT_ASSEMBLY")
			expect(f.compileErr(f.folder("Root")).errors[1].code).to.equal("ROOT_INVALID")
		end)

		it("rejects a non-Instance argument", function()
			local compiler = require(script.Parent.Parent)
			local compile = compiler.compile
			local compiled = compile("not an instance")
			expect(compiled.ok).to.equal(false)
			expect(compiled.err.errors[1].code).to.equal("ROOT_INVALID")
		end)

		it("warns about models named like nodes", function()
			local floor = f.compileOk(f.asm("Root", { f.model("asm Fake") }))
			expect(f.count(floor.warnings, "MODEL_NAMED_LIKE_NODE")).to.equal(1)
			expect(root(floor).children[1] ~= nil).to.equal(true)
		end)
	end)

	describe("structure", function()
		it("parses nested nodes", function()
			local floor = f.compileOk(f.asm("Root", {
				f.try("Outer", {
					f.asm("Inner", {
						f.try("Deep", { f.pick("Choice", 1, { f.asm("Leaf", { f.conditional("Thing") }) }) }),
					}),
				}),
			}))
			local outer = floor.nodes[root(floor).children[1].node]
			expect(outer.kind).to.equal("try")
			local inner = floor.nodes[outer.alternatives[1].node]
			expect(inner.kind).to.equal("assembly")
			local deep = floor.nodes[inner.children[1].node]
			expect(deep.kind).to.equal("try")
			local choice = floor.nodes[deep.alternatives[1].node]
			expect(choice.kind).to.equal("pick")
		end)

		it("ignores Folders and everything inside them", function()
			local floor = f.compileOk(f.asm("Root", {
				f.folder("Notes", {
					f.node("Part", "Anything goes here"),
					f.node("Configuration", "garbage name"),
					f.asm("Hidden", { f.conditional("WouldBeUnhandled") }),
					f.folder("Nested", { f.node("Script", "Code") }),
				}),
				f.model("Visible"),
			}))
			expect(#root(floor).children).to.equal(1)
			expect(#floor.nodes).to.equal(2)
		end)

		it("treats an empty try as a successful empty emission", function()
			local floor = f.compileOk(f.asm("Root", { f.try("Nothing") }))
			local t = floor.nodes[root(floor).children[1].node]
			expect(t.kind).to.equal("try")
			expect(#t.alternatives).to.equal(0)
			expect(t.mayFail).to.equal(false)
		end)

		it("preserves authored try order", function()
			local floor = f.compileOk(f.asm("Root", {
				f.try("Ordered", {
					f.conditional("Third"),
					f.conditional("First"),
					f.conditional("Second"),
				}),
			}))
			local t = floor.nodes[root(floor).children[1].node]
			local names = {}
			for _, alternative in t.alternatives do
				table.insert(names, floor.nodes[alternative.node].source.label)
			end
			expect(table.concat(names, ",")).to.equal("Third,First,Second")
		end)

		it("supports many try alternatives and nested tries", function()
			local alternatives = {}
			for i = 1, 6 do
				table.insert(alternatives, f.try("Nested" .. i, { f.conditional("M" .. i) }))
			end
			local floor = f.compileOk(f.asm("Root", { f.try("Many", alternatives) }))
			local t = floor.nodes[root(floor).children[1].node]
			expect(#t.alternatives).to.equal(6)
		end)

		it("allows assemblies and models as pick candidates", function()
			local crate = f.model("Elsewhere")
			local floor = f.compileOk(f.asm("Root", {
				f.pick("Mixed", 1, { f.asm("A"), f.model("M"), f.ref("ToModel", crate) }),
			}))
			local p = floor.nodes[root(floor).children[1].node]
			expect(#p.candidates).to.equal(3)
			expect(floor.nodes[p.candidates[2].edge.node].kind).to.equal("model")
		end)

		it("rejects other pick candidates", function()
			local failure = f.compileErr(f.asm("Root", {
				f.pick("Bad", 1, { f.try("NotACandidate"), f.pick("Nested", 0) }),
			}))
			expect(f.count(failure.errors, "PICK_CHILD_NOT_ASSEMBLY")).to.equal(2)
		end)

		it("parses each nodes", function()
			local floor = f.compileOk(f.asm("Root", {
				f.asm("Lobby", {
					f.room("Room", { connections = { { name = "DoorA", cframe = CFrame.new(1, 0, 0) } } }),
					f.each("Doors", { f.model("Sign") }),
				}),
			}))
			local lobby = floor.nodes[root(floor).children[1].node]
			expect(floor.nodes[lobby.children[2].node].kind).to.equal("each")
		end)
	end)
end
