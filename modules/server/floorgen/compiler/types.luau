--!strict
--[[
	Public types of the floor builder compiler.

	This module describes the compiled representation handed to the runtime
	floor builder, the diagnostics returned to developers, and the execution
	contract the builder must follow. It contains no logic.

	==========================================================================
	EXECUTION CONTRACT
	==========================================================================

	The compiled floor is a graph of nodes connected by edges. Generation is
	two-phase: PLAN (may fail, fully transactional) then COMMIT (cannot fail).

	Planner state is a set of append-only logs, all restored together:
		* planned emissions: (model_id, pivot CFrame) in emission order
		* accepted overlap volumes of conditional models
		* consumed connections: (scope, connection name)
		* counter increments (see fb_max_count)
	A checkpoint is the length of every log; restoring truncates them. Random
	streams are never restored: they are derived per node (see stream.luau).

	A "scope" is created for every assembly execution. Connections of the
	assembly's room are consumed in that scope.

	execute(edge, frame, scope, stream, ordinal) -> SUCCESS | FAIL
		if edge.optional:
			cp = checkpoint()
			if enter(...) == FAIL then restore(cp) end
			return SUCCESS
		return enter(...)

	enter(edge, frame, scope, stream, ordinal):
		if edge.recursive:
			if depth >= maxRecursionDepth then return FAIL end
			if edge.maxDepth and activeCount(edge) >= edge.maxDepth then return FAIL end
			(depth and activeCount(edge) are incremented while the target runs)
		if edge.connection:
			if scope has consumed edge.connection then return FAIL end
			consume edge.connection in scope
		pivot = frame * edge.placement
		childStream = stream.childSeed(stream, edge.key, ordinal)
		return run(nodes[edge.node], pivot, childStream, edge.anchor)

	Every node with a `counter` first checks its counter:
		if count[counter] >= node.maxCount then return FAIL end
		count[counter] += 1

	run(model, pivot):
		if model.conditional:
			volume = entry.overlap placed at pivot * entry.overlap.offset
			if volume overlaps any accepted volume then return FAIL end
			accept volume
		append emission (model.model, pivot)
		return SUCCESS

	run(assembly, pivot, stream, entryAnchor):
		cp = checkpoint()
		scope = new scope; if entryAnchor then consume entryAnchor in scope end
		for each child edge, in order:
			if execute(child, pivot, scope, stream, 0) == FAIL then
				restore(cp)
				return FAIL       -- every assembly is all-or-nothing
		for each plug edge, in order:
			if scope has not consumed plug.connection then
				execute(plug, pivot, scope, stream, 0)   -- never fails
		return SUCCESS

	run(try, pivot, scope):
		for each alternative edge, in order:
			cp = checkpoint()
			if execute(alternative, pivot, scope, stream, 0) == SUCCESS then return SUCCESS end
			restore(cp)
		return SUCCESS         -- exhausted: successful EMPTY emission

	run(each, pivot, scope):
		open = slots whose connection is unconsumed in scope right now
		for each slot edge in open, in order:
			if execute(slot, pivot, scope, stream, 0) == FAIL then return FAIL end
		return SUCCESS

	run(pick, pivot, scope, stream):
		rng = Random.new(stream)        -- the pick's own generator
		amount = pick.amountMin, or rng:NextInteger(amountMin, amountMax) if they differ
		strict mode: select `amount` candidates first (draw below), then execute
		    them in selection order (ordinal = selection index); any FAIL -> FAIL
		fit mode (ordinal = 1-based attempt index):
		    repeat until `amount` candidates succeeded:
		    if no candidate is eligible then return FAIL
		    draw one eligible candidate; cp = checkpoint(); execute it
		    on FAIL: restore(cp), the candidate becomes ineligible
		    on SUCCESS: if pick.unique the candidate becomes ineligible
		draw: total = sum of eligible weights; r = rng:NextInteger(1, total);
		    walk eligible candidates in order subtracting weights; the first
		    that brings r to <= 0 is drawn. In strict mode a drawn candidate
		    becomes ineligible only if pick.unique.

	`mayFail` on nodes and edges is the compiler's static over-approximation
	of whether FAIL can be returned. The compiler guarantees:
		* nodes[root].kind == "assembly" and it never fails
		* every FAIL is therefore handled by a try node or an optional edge
		* every cycle in the graph contains at least one `recursive` edge
		* a connection can only be found consumed on edges marked `contested`
		* plug edges never fail
		* all weights, amounts, placements and model metadata are validated;
		  the builder never inspects source Instances

	Commit iterates the planned emissions in order and instantiates each
	model entry at its pivot. Overlap volumes are never part of the template.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local result = require(ReplicatedStorage.shared.modules.result)

-- Diagnostics ---------------------------------------------------------------

export type severity = "error" | "warning"

export type diagnostic = {
	severity: severity,
	-- Stable machine-readable category, e.g. "PICK_AMOUNT_INVALID".
	code: string,
	-- Human readable explanation.
	message: string,
	-- Full name of the offending Instance at compile time.
	path: string?,
	-- The offending Instance itself, for selection in Studio.
	instance: Instance?,
	-- Relevant attribute, tag or property name.
	attribute: string?,
	-- Suggested correction.
	hint: string?,
}

export type compile_failure = {
	errors: { diagnostic },
	warnings: { diagnostic },
}

-- Compiled representation ---------------------------------------------------

export type node_id = number
export type model_id = number
export type counter_id = number

-- Where a compiled element came from. Strings only: the compiled floor keeps
-- no reference to the source hierarchy.
export type source_info = {
	label: string,
	path: string,
	className: string,
}

export type edge = {
	node: node_id,
	-- Transform from the enclosing frame to the child's pivot.
	placement: CFrame,
	-- On a cycle: consumes recursion depth and fails beyond the limit.
	recursive: boolean,
	-- Per-reference recursion limit (recursive edges only).
	maxDepth: number?,
	-- fb_optional: failures are handled on this edge.
	optional: boolean,
	-- Connection of the current scope consumed by entering this edge.
	connection: string?,
	-- Connection of the child's own room that is consumed on arrival.
	anchor: string?,
	-- Another use of `connection` may have consumed it first.
	contested: boolean,
	-- Whether executing this edge can FAIL.
	mayFail: boolean,
	-- Stable key for random stream derivation (see stream.luau).
	key: number,
	-- The Instance (inline node or reference) that created this edge.
	source: source_info,
}

export type candidate = {
	edge: edge,
	-- Natural number. Candidates with weight 0 are never selected.
	weight: number,
}

export type assembly_node = {
	kind: "assembly",
	id: node_id,
	-- Model registry entry of the room whose PrimaryPart is this assembly's pivot.
	room: model_id?,
	children: { edge },
	-- At most one per room connection, in connection name order.
	plugs: { edge },
	counter: counter_id?,
	maxCount: number?,
	mayFail: boolean,
	source: source_info,
}

export type try_node = {
	kind: "try",
	id: node_id,
	alternatives: { edge },
	-- Always false: a try node never fails.
	mayFail: boolean,
	source: source_info,
}

export type fb_pick_mode = "strict" | "fit"

export type pick_node = {
	kind: "pick",
	id: node_id,
	amountMin: number,
	amountMax: number,
	unique: boolean,
	mode: fb_pick_mode,
	-- In authored order. Every candidate targets an assembly or model node.
	candidates: { candidate },
	totalWeight: number,
	mayFail: boolean,
	source: source_info,
}

export type each_node = {
	kind: "each",
	id: node_id,
	-- One edge per matching room connection, in connection name order. All
	-- slots target the same node; each consumes its own connection.
	slots: { edge },
	mayFail: boolean,
	source: source_info,
}

export type model_node = {
	kind: "model",
	id: node_id,
	model: model_id,
	conditional: boolean,
	counter: counter_id?,
	maxCount: number?,
	mayFail: boolean,
	source: source_info,
}

export type node = assembly_node | try_node | pick_node | each_node | model_node

export type connection = {
	name: string,
	-- Attachment frame relative to the model's PrimaryPart.
	offset: CFrame,
}

export type overlap_volume = {
	-- Overlap part frame relative to the model's PrimaryPart.
	offset: CFrame,
	size: Vector3,
	-- Returns a fresh, unparented copy of the private overlap part.
	instantiate: () -> BasePart,
}

export type model_entry = {
	id: model_id,
	name: string,
	sourcePath: string,
	-- Sorted by name.
	connections: { connection },
	overlap: overlap_volume?,
	-- Returns a fresh, unparented copy of the private template. The template
	-- never contains the overlap part.
	instantiate: () -> Model,
}

export type compiled_floor = {
	formatVersion: number,
	root: node_id,
	-- Indexed by node_id.
	nodes: { node },
	-- Indexed by model_id.
	models: { model_entry },
	-- Number of counters (counter ids are 1..counters).
	counters: number,
	warnings: { diagnostic },
}

-- Tooling --------------------------------------------------------------------

export type outline_kind = "assembly" | "try" | "pick" | "each" | "model" | "reference" | "invalid"

export type outline_key = {
	-- Attribute or tag name.
	name: string,
	-- Attribute value as text; nil for tags.
	value: string?,
}

-- One source Instance of the language, annotated with what the compiler
-- found out about it. Built for editors and plugins; it references source
-- Instances and is not meant for the runtime builder.
export type outline_node = {
	instance: Instance,
	kind: outline_kind,
	label: string,
	-- Language keys set directly on this Instance.
	keys: { outline_key },
	children: { outline_node },
	-- References: the target and its kind.
	target: Instance?,
	targetKind: outline_kind?,
	-- Whether this Instance is part of the compiled graph.
	compiled: boolean,
	-- Whether this node (or, for references, its use) can fail at runtime.
	mayFail: boolean,
	-- Whether a failure here is handled right here (fb_optional).
	handled: boolean,
	recursive: boolean,
	contested: boolean,
	-- Diagnostics whose Instance is this one.
	diagnostics: { diagnostic },
}

export type analysis = {
	result: compile_result,
	-- Outline of the root hierarchy (nil when the root is unusable).
	root: outline_node?,
	-- Referenced definitions that live outside the root hierarchy.
	definitions: { outline_node },
	-- Every diagnostic, errors first.
	diagnostics: { diagnostic },
	-- Seconds spent compiling and analysing.
	elapsed: number,
}

-- Public API ----------------------------------------------------------------

export type compile_result = result.result<compiled_floor, compile_failure>

return table.freeze({})
