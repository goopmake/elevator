--!strict
--[[
	Spatial composition.

	Every placed child (model or assembly) gets a `placement`: the transform
	from the enclosing frame to the child's pivot. Try and pick nodes are
	spatially transparent; edges into them have identity placement and their
	children are placed relative to the same enclosing frame.

	Pivots
		* model:    its PrimaryPart
		* assembly: the PrimaryPart of its room, i.e. the direct child model
		            whose effective tags contain fb_room. An assembly without a
		            room has no geometry of its own; its pivot is the enclosing
		            frame (identity placement unless fb_attach moves it).

	Placement of a child, in priority order
		1. fb_attach: the child is placed on the named connection of the room of
		   the nearest enclosing assembly in the same definition (through try
		   and pick nodes). With fb_anchor the child's own connection is mated
		   to it (see constants.CONNECTION_MATE).
		2. Authored: a child declared inline keeps the transform it has in the
		   source relative to the enclosing authoring frame, so what is seen in
		   Studio is what is generated.
		3. Otherwise (a reference without fb_attach): identity.

	Authoring frames are derived from the physical source hierarchy only:
		* assembly with an inline room: the room's PrimaryPart CFrame
		* assembly whose room is a reference: unknown (the room is physically
		  elsewhere), so authored placement is unavailable inside it
		* assembly without room, try, pick, each: the frame of the source parent if
		  that is a container node, otherwise the world origin
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = require(ReplicatedStorage.shared.modules.result)

local constants = require(script.Parent.Parent.constants)
local diagnostics = require(script.Parent.Parent.diagnostics)
local ir = require(script.Parent.Parent.ir)
local parser = require(script.Parent.Parent.parser)
local resolution = require(script.Parent.Parent.resolution)
local models = require(script.Parent.models)

type session = ir.session
type model_facts = ir.model_facts
type container_kind = ir.container_kind
type outcome<T> = diagnostics.outcome<T>

local errors = diagnostics.codes.errors

export type room_lookup =
	{ kind: "none" }
	| { kind: "inline", instance: Model }
	| { kind: "reference", instance: ObjectValue, model: Model }
	| { kind: "ambiguous", instances: { Instance } }

-- The pivot model of something, or why there is none.
export type pivot_lookup =
	{ kind: "ok", facts: model_facts }
	-- No pivot model at all.
	| { kind: "none" }
	-- Several rooms; reported as ROOM_DUPLICATE.
	| { kind: "ambiguous" }
	-- The model exists but is invalid; reported by model inspection.
	| { kind: "invalid" }

export type state = {
	session: session,
	rooms: { [Instance]: room_lookup },
	-- false: unknown frame.
	frames: { [Instance]: CFrame | false },
}

local function newState(session: session): state
	return {
		session = session,
		rooms = {},
		frames = {},
	}
end

local function containerKind(instance: Instance): container_kind?
	if instance.ClassName ~= constants.CLASS.container then
		return nil
	end
	local classified = parser.classify(instance)
	if classified.ok and classified.val.kind == "container" then
		return classified.val.nodeKind
	end
	return nil
end

-- Finds the room of an assembly from its direct children. This is the single
-- rule used for room detection everywhere.
local function findRoom(state: state, assembly: Instance): room_lookup
	local memo = state.rooms[assembly]
	if memo then
		return memo
	end

	local found: { room_lookup } = {}
	for _, child in assembly:GetChildren() do
		if child.ClassName == constants.CLASS.model and child:IsA("Model") then
			if child:HasTag(constants.TAG.room) then
				local room: room_lookup = { kind = "inline", instance = child }
				table.insert(found, room)
			end
		elseif child.ClassName == constants.CLASS.reference and child:IsA("ObjectValue") then
			local classified = parser.classify(child)
			if classified.ok and classified.val.kind == "reference" then
				local effective = resolution.peekEffectiveTags(child)
				local target = resolution.peekTarget(child)
				if
					effective
					and effective[constants.TAG.room]
					and target
					and target.ClassName == constants.CLASS.model
					and target:IsA("Model")
				then
					local room: room_lookup = { kind = "reference", instance = child, model = target }
					table.insert(found, room)
				end
			end
		end
	end

	local lookup: room_lookup
	if #found == 0 then
		lookup = { kind = "none" }
	elseif #found == 1 then
		lookup = found[1]
	else
		local instances: { Instance } = {}
		for _, room in found do
			if room.kind == "inline" or room.kind == "reference" then
				table.insert(instances, room.instance)
			end
		end
		lookup = { kind = "ambiguous", instances = instances }
	end
	state.rooms[assembly] = lookup
	return lookup
end

local function pivotOfModel(state: state, model: Model): pivot_lookup
	local inspected = models.inspect(state.session, model)
	if inspected.ok then
		return { kind = "ok", facts = inspected.val }
	end
	return { kind = "invalid" }
end

-- The room of an assembly as a pivot lookup.
local function roomPivot(state: state, assembly: Instance): pivot_lookup
	local room = findRoom(state, assembly)
	if room.kind == "inline" then
		return pivotOfModel(state, room.instance)
	elseif room.kind == "reference" then
		return pivotOfModel(state, room.model)
	elseif room.kind == "ambiguous" then
		return { kind = "ambiguous" }
	end
	return { kind = "none" }
end

-- Model facts of an assembly's room, if it has exactly one valid room.
local function roomFacts(state: state, assembly: Instance): model_facts?
	local pivot = roomPivot(state, assembly)
	return if pivot.kind == "ok" then pivot.facts else nil
end

local authoringFrame: (state: state, container: Instance) -> CFrame?

local function parentFrame(state: state, container: Instance): CFrame?
	local parent = container.Parent
	if parent and containerKind(parent) then
		return authoringFrame(state, parent)
	end
	return CFrame.identity
end

function authoringFrame(state: state, container: Instance): CFrame?
	local memo = state.frames[container]
	if typeof(memo) == "CFrame" then
		return memo
	elseif memo == false then
		return nil
	end
	-- Guard against pathological re-entry while computing.
	state.frames[container] = false

	local frame: CFrame? = nil
	local kind = containerKind(container)
	if kind == "assembly" then
		local room = findRoom(state, container)
		if room.kind == "inline" then
			local inspected = models.inspect(state.session, room.instance)
			frame = if inspected.ok then inspected.val.pivot else nil
		elseif room.kind == "none" then
			frame = parentFrame(state, container)
		else
			frame = nil
		end
	elseif kind == "try" or kind == "pick" or kind == "each" then
		frame = parentFrame(state, container)
	end

	state.frames[container] = if frame then frame else false
	return frame
end

-- The assembly whose room `fb_attach` refers to for children of `container`:
-- the container itself if it is an assembly, otherwise the nearest assembly
-- reached by walking up through try and pick nodes in the source.
local function attachmentAssembly(container: Instance): Instance?
	local current: Instance? = container
	while current do
		local kind = containerKind(current)
		if kind == "assembly" then
			return current
		elseif kind == "try" or kind == "pick" or kind == "each" then
			current = current.Parent
		else
			return nil
		end
	end
	return nil
end

-- Whether children of `container` have a room they could fb_attach to.
local function hasAttachmentRoom(state: state, container: Instance): boolean
	local assembly = attachmentAssembly(container)
	return assembly ~= nil and roomFacts(state, assembly) ~= nil
end

local matePlacement: (owner: Instance, parentConnection: CFrame, anchor: string?, anchorPivot: pivot_lookup) -> outcome<CFrame>

-- Resolves fb_attach / fb_anchor into a placement. `anchorPivot` is the pivot
-- model of the child being placed.
local function attachPlacement(
	state: state,
	owner: Instance,
	parentContainer: Instance,
	attach: string,
	anchor: string?,
	anchorPivot: pivot_lookup
): outcome<CFrame>
	local assembly = attachmentAssembly(parentContainer)
	local room: pivot_lookup = if assembly then roomPivot(state, assembly) else { kind = "none" }
	if room.kind == "invalid" then
		-- The room itself is broken and already reported; do not cascade.
		return result.err({})
	elseif room.kind == "ambiguous" then
		return diagnostics.fail(
			errors.ATTACH_NO_ROOM,
			owner,
			"fb_attach needs a single room on the enclosing assembly, but it has several.",
			{ attribute = constants.ATTRIBUTE.attach, hint = "Keep exactly one fb_room model in the assembly." }
		)
	elseif room.kind == "none" then
		return diagnostics.fail(
			errors.ATTACH_NO_ROOM,
			owner,
			"fb_attach needs an enclosing assembly with a room, but there is none in this definition.",
			{
				attribute = constants.ATTRIBUTE.attach,
				hint = "Tag a direct child model of the enclosing assembly with fb_room, or remove fb_attach.",
			}
		)
	end
	local facts = room.facts

	local parentConnection: CFrame? = facts.connectionByName[attach]
	if parentConnection == nil then
		local names = {}
		for _, connection in facts.connections do
			table.insert(names, connection.name)
		end
		return diagnostics.fail(
			errors.ATTACH_UNKNOWN_CONNECTION,
			owner,
			string.format("The room %s has no connection named '%s'.", facts.path, attach),
			{
				attribute = constants.ATTRIBUTE.attach,
				hint = if #names > 0
					then "Available connections: " .. table.concat(names, ", ") .. "."
					else "The room has no Attachments tagged fb_connection.",
			}
		)
	end

	return matePlacement(owner, parentConnection, anchor, anchorPivot)
end

-- Places a child on a known parent connection frame, mating its own anchor
-- connection when one is given.
function matePlacement(
	owner: Instance,
	parentConnection: CFrame,
	anchor: string?,
	anchorPivot: pivot_lookup
): outcome<CFrame>
	if anchor == nil then
		return result.ok(parentConnection)
	end

	if anchorPivot.kind == "invalid" then
		return result.err({})
	elseif anchorPivot.kind == "ambiguous" then
		return diagnostics.fail(
			errors.ANCHOR_NO_PIVOT_MODEL,
			owner,
			"fb_anchor needs a single room on the placed assembly, but it has several.",
			{ attribute = constants.ATTRIBUTE.anchor }
		)
	elseif anchorPivot.kind == "none" then
		return diagnostics.fail(
			errors.ANCHOR_NO_PIVOT_MODEL,
			owner,
			"fb_anchor needs a model to anchor, but this assembly has no room.",
			{ attribute = constants.ATTRIBUTE.anchor, hint = "Give the assembly a room, or remove fb_anchor." }
		)
	end
	local anchorFacts = anchorPivot.facts

	local own: CFrame? = anchorFacts.connectionByName[anchor]
	if own == nil then
		return diagnostics.fail(
			errors.ANCHOR_UNKNOWN_CONNECTION,
			owner,
			string.format("%s has no connection named '%s'.", anchorFacts.path, anchor),
			{ attribute = constants.ATTRIBUTE.anchor }
		)
	end

	return result.ok(parentConnection * constants.CONNECTION_MATE * own:Inverse())
end

-- Authored placement of an inline child: its authoring frame expressed in the
-- parent's authoring frame. Nil when either frame is unknown.
local function authoredPlacement(parentFrame: CFrame?, childFrame: CFrame?): CFrame?
	if parentFrame == nil or childFrame == nil then
		return nil
	end
	return parentFrame:ToObjectSpace(childFrame)
end

return table.freeze({
	newState = newState,
	findRoom = findRoom,
	roomFacts = roomFacts,
	roomPivot = roomPivot,
	attachmentAssembly = attachmentAssembly,
	matePlacement = matePlacement,
	authoringFrame = authoringFrame,
	attachPlacement = attachPlacement,
	hasAttachmentRoom = hasAttachmentRoom,
	authoredPlacement = authoredPlacement,
})
