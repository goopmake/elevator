--!strict
--[[
	Public types of the floor builder.

	The builder executes a compiled floor (see compiler/types.luau for the
	execution contract) in two phases:

		plan(floor, options)   decides every placement; may only fail on bad
		                       input or a compiler defect, never because of
		                       generation outcomes (those are handled inside)
		commit(plan, parent)   spawns the planned models; cannot fail

	A plan is immutable and can be committed any number of times.
]]

local compiler = require(script.Parent.Parent.compiler)

export type error_code = "OPTIONS_INVALID" | "FLOOR_INVALID" | "COMPILER_DEFECT"

export type builder_error = {
	code: error_code,
	message: string,
}

-- Collision world used during planning. The default implementation places
-- private copies of overlap parts in a WorldModel and queries it with
-- GetPartsInPart (full geometric checks, rotated parts, unions).
export type collision_world = {
	-- Accepts the overlap volume of `entry` at `cframe` (the volume's own
	-- frame, i.e. pivot * overlap.offset) unless it overlaps an accepted one.
	tryAccept: (entry: compiler.model_entry, cframe: CFrame) -> boolean,
	-- Number of accepted volumes.
	size: () -> number,
	-- Removes the most recently accepted volumes until `size` remain.
	truncate: (size: number) -> (),
	-- Releases every resource. Called once when planning ends.
	destroy: () -> (),
}

export type collision_context = {
	-- Where a world may parent temporary Instances.
	parent: Instance,
}

export type collision_factory = (context: collision_context) -> collision_world

export type options = {
	-- Any finite number. Equal seeds give equal floors.
	seed: number,
	-- Maximum number of nested recursive references (default 8).
	maxRecursionDepth: number?,
	-- Frame of the root assembly's pivot (default identity).
	origin: CFrame?,
	-- Collision world (default: WorldModel based).
	collision: collision_factory?,
	-- Parent for the temporary planning WorldModel (default ServerStorage).
	planningParent: Instance?,
	-- When set, planning yields (task.wait) whenever it has run this many
	-- seconds without yielding, so large floors do not hit script timeouts.
	yieldBudget: number?,
	-- Record pick selections and failures in plan.trace.
	trace: boolean?,
}

export type emission = {
	model: compiler.model_id,
	-- Frame of the model's PrimaryPart.
	pivot: CFrame,
	-- Node that emitted it.
	node: compiler.node_id,
}

export type failure_reason = "overlap" | "count" | "recursion" | "connection"

export type stats = {
	-- Node executions, including ones that were rolled back.
	executions: number,
	-- Failures by reason (all of them handled).
	failures: { [failure_reason]: number },
}

export type trace_pick = {
	node: compiler.node_id,
	-- Indices into the pick's candidates, in selection order. In fit mode,
	-- only the candidates that succeeded.
	chosen: { number },
}

export type trace_failure = {
	reason: failure_reason,
	node: compiler.node_id,
	-- The edge that failed, when the failure happened on entering an edge.
	source: compiler.source_info?,
	-- Where the failed placement would have been.
	pivot: CFrame,
}

export type trace = {
	picks: { trace_pick },
	failures: { trace_failure },
}

export type plan = {
	floor: compiler.compiled_floor,
	seed: number,
	origin: CFrame,
	-- In commit order.
	emissions: { emission },
	-- Final emission count per counter id.
	counters: { number },
	stats: stats,
	trace: trace?,
}

return table.freeze({})
