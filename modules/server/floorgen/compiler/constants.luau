--!strict
--[[
	Language constants.

	Every name, tag, attribute and spatial convention of the floor builder
	language is defined here and nowhere else. Other modules must refer to these
	values instead of repeating string literals.
]]

-- Node identification ------------------------------------------------------

-- A node name is `<prefix><PREFIX_SEPARATOR><label>`. The label is free-form
-- and carries no semantics (it may even be empty).
local PREFIX_SEPARATOR = " "

local PREFIX = table.freeze({
	assembly = "asm",
	try = "try",
	pick = "pick",
	each = "each",
	reference = "ref",
})

-- Instance classes ---------------------------------------------------------

local CLASS = table.freeze({
	-- Container nodes (asm / try / pick / each).
	container = "Configuration",
	-- Reference nodes.
	reference = "ObjectValue",
	-- Model declarations.
	model = "Model",
	-- Hard language boundary: never interpreted.
	boundary = "Folder",
})

-- CollectionService tags ---------------------------------------------------

local TAG = table.freeze({
	-- On a model: takes part in overlap checks and may fail to emit.
	conditional = "fb_conditional_model",
	-- On a model that is a direct child of an assembly: the assembly's room.
	-- The room's PrimaryPart is the assembly's pivot.
	room = "fb_room",
	-- On a model that is a direct child of an assembly with a room: placed on
	-- every connection of the room that is still unused when the assembly
	-- finishes (e.g. a wall segment sealing a doorway).
	plug = "fb_plug",
	-- On any child: its failure is caught right there, exactly like wrapping
	-- it in a try node with a single alternative.
	optional = "fb_optional",
	-- On a reference: its behaviour keys replace the target's completely,
	-- even when it sets none (this is how behaviour tags are removed).
	override = "fb_override",
	-- On an Attachment inside a model: a named connection point.
	connection = "fb_connection",
	-- Removed: every assembly is all-or-nothing now. Reported as a warning.
	removedAtomic = "fb_atomic_assembly",
})

-- Attributes ---------------------------------------------------------------

local ATTRIBUTE = table.freeze({
	-- pick: how many candidates to select. Required. A natural number, or a
	-- NumberRange of natural numbers for a random count.
	pickAmount = "fb_pick_amount",
	-- pick: whether a candidate may be selected at most once. Default false.
	pickUnique = "fb_pick_unique",
	-- pick: "strict" (default) or "fit".
	pickMode = "fb_pick_mode",
	-- pick candidate: relative weight. Default 1. Natural number.
	pickWeight = "fb_pick_weight",
	-- model / assembly: connection on the enclosing room to place this on.
	attach = "fb_attach",
	-- model / assembly: own connection mated with the parent connection.
	anchor = "fb_anchor",
	-- each node / plug model: connection name prefix to act on. Default: all.
	filter = "fb_filter",
	-- reference: how many times this reference may be active at once on the
	-- current expansion path (a per-reference recursion limit).
	maxDepth = "fb_max_depth",
	-- model / assembly: how many times the definition may be emitted in one
	-- generated floor, counted across all of its uses.
	maxCount = "fb_max_count",
})

local PICK_MODES = table.freeze({ "strict", "fit" })

--[[
	Key categories.

	Behaviour keys describe what a node IS. A reference that sets any of them
	overrides its target's behaviour keys completely (unset ones are removed).

	Use-site keys describe how a node is USED at one place (placement, weight,
	role, failure handling). They never trigger an override: a reference's
	use-site keys are layered on top of the target's, key by key.
]]
local BEHAVIOUR_KEYS: { [string]: boolean } = table.freeze({
	[TAG.conditional] = true,
	[ATTRIBUTE.pickAmount] = true,
	[ATTRIBUTE.pickUnique] = true,
	[ATTRIBUTE.pickMode] = true,
	[ATTRIBUTE.maxCount] = true,
})

-- Every attribute or tag whose name starts with one of these prefixes belongs
-- to the language. Unknown names in these namespaces are reported as errors
-- (they are almost always typos). Anything else is developer data.
local ATTRIBUTE_NAMESPACES: { string } = table.freeze({ "fb_" })
local TAG_NAMESPACES: { string } = table.freeze({ "fb_" })

-- Models -------------------------------------------------------------------

-- Name of the BasePart that defines a conditional model's collision volume.
local OVERLAP_PART_NAME = "overlap"

-- Numeric limits -----------------------------------------------------------

-- Largest integer that a double represents exactly. Weights and their sum must
-- stay at or below this so weighted selection arithmetic is exact.
local MAX_EXACT_INTEGER = 2 ^ 53

-- Spatial conventions ------------------------------------------------------

--[[
	Connection mating rule.

	Connection Attachments are authored with their LookVector pointing *out of*
	the room (through the doorway). When a child's `fb_anchor` connection is
	mated with a parent's `fb_attach` connection, both attachments coincide in
	position and face opposite directions. That is a half turn about the
	attachment's own UpVector:

		childPivot = parentAttachment * CONNECTION_MATE * anchor:Inverse()

	Without `fb_anchor` the child's pivot (its PrimaryPart) is placed exactly on
	the parent attachment, with the attachment's orientation:

		childPivot = parentAttachment
]]
local CONNECTION_MATE = CFrame.Angles(0, math.pi, 0)

-- Compiled format ----------------------------------------------------------

-- Incremented whenever the compiled representation changes incompatibly.
local FORMAT_VERSION = 2

return table.freeze({
	PREFIX_SEPARATOR = PREFIX_SEPARATOR,
	PREFIX = PREFIX,
	CLASS = CLASS,
	TAG = TAG,
	ATTRIBUTE = ATTRIBUTE,
	PICK_MODES = PICK_MODES,
	BEHAVIOUR_KEYS = BEHAVIOUR_KEYS,
	ATTRIBUTE_NAMESPACES = ATTRIBUTE_NAMESPACES,
	TAG_NAMESPACES = TAG_NAMESPACES,
	OVERLAP_PART_NAME = OVERLAP_PART_NAME,
	MAX_EXACT_INTEGER = MAX_EXACT_INTEGER,
	CONNECTION_MATE = CONNECTION_MATE,
	FORMAT_VERSION = FORMAT_VERSION,
})
