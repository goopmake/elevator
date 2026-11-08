--!nonstrict
local f = require(script.Parent.fixtures)
local planner = require(script.Parent.planning)

local function root(floor)
	return floor.nodes[floor.root]
end

local function near(a, b)
	return f.cframeNear(a, b, 1e-3)
end

local function vnear(a, b)
	return (a - b).Magnitude < 1e-3
end

return function()
	describe("authored placement", function()
		it("preserves a model's position inside its room", function()
			local roomFrame = CFrame.new(100, 5, -20) * CFrame.Angles(0, math.pi / 2, 0)
			local local_ = CFrame.new(1, 2, 3) * CFrame.Angles(0, 0.4, 0)
			local source = f.asm("Root", {
				f.asm("Lobby", {
					f.room("LobbyRoom", { cframe = roomFrame }),
					f.try("Clock", { f.conditional("Clock", { cframe = roomFrame * local_ }) }),
				}),
			})
			local floor = f.compileOk(source)
			local lobbyEdge = root(floor).children[1]
			local lobby = floor.nodes[lobbyEdge.node]
			expect(lobby.room).to.equal(1)
			expect(near(lobbyEdge.placement, roomFrame)).to.equal(true)
			expect(near(lobby.children[1].placement, CFrame.identity)).to.equal(true)
			local clockTry = floor.nodes[lobby.children[2].node]
			expect(near(clockTry.alternatives[1].placement, local_)).to.equal(true)

			-- Moving the floor keeps the authored relationship.
			local origin = CFrame.new(-7, 0, 9) * CFrame.Angles(0, 1.1, 0)
			local plan = planner.run(floor, { seed = 1, maxRecursionDepth = 0, origin = origin })
			expect(#plan.emissions).to.equal(2)
			local room, clock = plan.emissions[1].pivot, plan.emissions[2].pivot
			expect(near(room:ToObjectSpace(clock), local_)).to.equal(true)
		end)

		it("gives assemblies without a room their parent's frame", function()
			local roomFrame = CFrame.new(10, 0, 0)
			local floor = f.compileOk(f.asm("Root", {
				f.asm("Lobby", {
					f.room("Room", { cframe = roomFrame }),
					f.asm("Furniture", { f.model("Chair", { cframe = roomFrame * CFrame.new(2, 0, 0) }) }),
				}),
			}))
			local lobby = floor.nodes[root(floor).children[1].node]
			local furnitureEdge = lobby.children[2]
			expect(near(furnitureEdge.placement, CFrame.identity)).to.equal(true)
			local furniture = floor.nodes[furnitureEdge.node]
			expect(near(furniture.children[1].placement, CFrame.new(2, 0, 0))).to.equal(true)
		end)

		it("warns when the authored position is unknowable", function()
			local libraryRoom = f.room("LibraryRoom", { cframe = CFrame.new(500, 0, 0) })
			local floor = f.compileOk(f.asm("Root", {
				f.folder("Library", { libraryRoom }),
				f.asm("Lobby", {
					f.ref("Room", libraryRoom),
					f.model("Chair", { cframe = CFrame.new(3, 0, 0) }),
				}),
			}))
			-- Both the Lobby (its own room is a reference) and the Chair (its
			-- enclosing room is a reference) lack an authored position.
			expect(f.count(floor.warnings, "PLACEMENT_UNAVAILABLE")).to.equal(2)
		end)
	end)

	describe("connections", function()
		local east = CFrame.new(10, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0) -- looks +X
		local west = CFrame.new(-5, 0, 0) * CFrame.Angles(0, math.pi / 2, 0) -- looks -X

		local function lobbyWith(children)
			local list = { f.room("LobbyRoom", { connections = { { name = "East", cframe = east } } }) }
			for _, c in children do
				table.insert(list, c)
			end
			return f.asm("Root", { f.asm("Lobby", list) })
		end

		it("records validated connection metadata in the registry", function()
			local floor = f.compileOk(f.asm("Root", {
				f.room("Room", {
					connections = {
						{ name = "Zulu", cframe = CFrame.new(0, 0, 1) },
						{ name = "Alpha", cframe = CFrame.new(0, 0, 2) },
					},
				}),
			}))
			local connections = floor.models[1].connections
			expect(#connections).to.equal(2)
			expect(connections[1].name).to.equal("Alpha")
			expect(near(connections[1].offset, CFrame.new(0, 0, 2))).to.equal(true)
			expect(connections[2].name).to.equal("Zulu")
		end)

		it("places a child pivot on a parent connection", function()
			local hall = f.asm("Hall", { f.room("HallRoom") })
			local floor = f.compileOk(lobbyWith({
				f.folder("Library", { hall }),
				f.try("Side", { f.ref("Hall", hall, { attributes = { fb_attach = "East" } }) }),
			}))
			local lobby = floor.nodes[root(floor).children[1].node]
			local side = floor.nodes[lobby.children[2].node]
			expect(near(side.alternatives[1].placement, east)).to.equal(true)
		end)

		it("mates an anchor connection with the parent connection", function()
			local hall = f.asm("Hall", { f.room("HallRoom", { connections = { { name = "West", cframe = west } } }) })
			local floor = f.compileOk(lobbyWith({
				f.folder("Library", { hall }),
				f.ref("Hall", hall, { attributes = { fb_attach = "East", fb_anchor = "West" } }),
			}))
			local lobby = floor.nodes[root(floor).children[1].node]
			local pivot = lobby.children[2].placement
			local mated = pivot * west
			expect(vnear(mated.Position, east.Position)).to.equal(true)
			expect(vnear(mated.LookVector, -east.LookVector)).to.equal(true)
			expect(vnear(mated.UpVector, east.UpVector)).to.equal(true)
		end)

		it("rejects unknown connections", function()
			local hall = f.asm("Hall", { f.room("HallRoom", { connections = { { name = "West", cframe = west } } }) })
			local failure = f.compileErr(lobbyWith({
				f.folder("Library", { hall }),
				f.ref("BadAttach", hall, { attributes = { fb_attach = "North" } }),
				f.ref("BadAnchor", hall, { attributes = { fb_attach = "East", fb_anchor = "South" } }),
			}))
			local d = f.find(failure.errors, "ATTACH_UNKNOWN_CONNECTION")
			expect(d).to.be.ok()
			expect(string.find(d.hint, "East", 1, true)).to.be.ok()
			expect(f.count(failure.errors, "ANCHOR_UNKNOWN_CONNECTION")).to.equal(1)
		end)

		it("rejects fb_attach without an enclosing room", function()
			local failure = f.compileErr(f.asm("Root", {
				f.model("Thing", { attributes = { fb_attach = "Door" } }),
			}))
			expect(f.count(failure.errors, "ATTACH_NO_ROOM")).to.equal(1)
		end)

		it("rejects fb_anchor on an assembly without a room", function()
			local failure = f.compileErr(lobbyWith({
				f.asm("NoRoom", {}, { attributes = { fb_attach = "East", fb_anchor = "West" } }),
			}))
			expect(f.count(failure.errors, "ANCHOR_NO_PIVOT_MODEL")).to.equal(1)
		end)

		it("rejects fb_anchor without fb_attach and fb_attach on try nodes", function()
			local failure = f.compileErr(lobbyWith({
				f.model("Thing", { attributes = { fb_anchor = "X" } }),
				f.node("Configuration", "try T", { attributes = { fb_attach = "East" } }),
			}))
			expect(f.count(failure.errors, "ANCHOR_WITHOUT_ATTACH")).to.equal(1)
			expect(f.count(failure.errors, "ATTRIBUTE_NOT_APPLICABLE")).to.equal(1)
		end)

		it("gives recursive emissions independent transforms", function()
			local corridor = f.asm("Corridor", {
				f.room("CorridorRoom", {
					connections = {
						{ name = "In", cframe = CFrame.new(0, 0, -5) },
						{ name = "Out", cframe = CFrame.new(0, 0, 5) * CFrame.Angles(0, math.pi, 0) },
					},
				}),
			})
			f.try("More", {
				f.ref("Next", corridor, { attributes = { fb_attach = "Out", fb_anchor = "In" } }),
			}).Parent = corridor
			local floor = f.compileOk(f.asm("Root", { f.folder("Library", { corridor }), f.ref("Start", corridor) }))
			local plan = planner.run(floor, { seed = 1, maxRecursionDepth = 3 })
			expect(#plan.emissions).to.equal(4)
			for i, emission in plan.emissions do
				expect(emission.model).to.equal(1)
				expect(vnear(emission.pivot.Position, Vector3.new(0, 0, 10 * (i - 1)))).to.equal(true)
			end
		end)
	end)

	describe("rooms", function()
		it("rejects several rooms in one assembly", function()
			local failure = f.compileErr(f.asm("Root", { f.room("A"), f.room("B") }))
			expect(f.count(failure.errors, "ROOM_DUPLICATE")).to.equal(1)
		end)

		it("rejects rooms that are not direct children of an assembly", function()
			local failure = f.compileErr(f.asm("Root", { f.try("T", { f.room("Nested") }) }))
			expect(f.count(failure.errors, "ROOM_NOT_DIRECT_CHILD")).to.equal(1)
		end)

		it("rejects attached rooms", function()
			local failure = f.compileErr(f.asm("Root", {
				f.room("R", { attributes = { fb_attach = "X" } }),
			}))
			expect(f.count(failure.errors, "ROOM_ATTACHED")).to.equal(1)
		end)

		it("accepts a room provided through a reference", function()
			local libraryRoom = f.room("LibraryRoom", { connections = { { name = "Door", cframe = CFrame.new(0, 0, 3) } } })
			local floor = f.compileOk(f.asm("Root", {
				f.folder("Library", { libraryRoom }),
				f.asm("Lobby", {
					f.ref("Room", libraryRoom),
					f.ref("Lamp", f.model("Lamp"), { attributes = { fb_attach = "Door" } }),
				}),
			}))
			local lobby = floor.nodes[root(floor).children[1].node]
			expect(lobby.room).to.equal(1)
			expect(near(lobby.children[2].placement, CFrame.new(0, 0, 3))).to.equal(true)
		end)
	end)
end
