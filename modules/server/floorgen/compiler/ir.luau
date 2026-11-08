--!strict
--[[
	Internal intermediate representation shared by the compiler stages.

	Nothing here is part of the public API. The IR refers to source Instances;
	the compiled representation (see types.luau) does not.
]]

local types = require(script.Parent.types)
local diagnostics = require(script.Parent.diagnostics)

export type node_kind = "assembly" | "try" | "pick" | "each" | "model"
export type container_kind = "assembly" | "try" | "pick" | "each"

-- Language keys read from an Instance. Values are not validated yet.
export type raw_config = {
	attributes: { [string]: unknown },
	-- Sorted, for deterministic iteration.
	attributeNames: { string },
	-- Sorted.
	tags: { string },
}

-- Validated configuration of a node at one use.
export type node_config = {
	-- Behaviour keys (distinguish compiled node specialisations).
	conditional: boolean,
	maxCount: number?,
	pickMin: number?,
	pickMax: number?,
	pickUnique: boolean,
	pickMode: types.fb_pick_mode,
	-- Use-site keys (stored on edges or as roles).
	room: boolean,
	plug: boolean,
	optional: boolean,
	pickWeight: number?,
	attach: string?,
	anchor: string?,
	filter: string?,
	maxDepth: number?,
}

-- A validated configuration together with the language keys that were
-- actually present (needed to layer reference use-site keys over a target).
export type parsed_config = {
	config: node_config,
	present: { [string]: boolean },
}

-- A use of a definition through an ObjectValue.
export type reference_use = {
	instance: ObjectValue,
	label: string,
	path: string,
	-- Language keys on the ObjectValue. Non-empty means it overrides.
	ownConfig: raw_config,
}

export type inline_child = {
	kind: "inline",
	instance: Instance,
	definition: number,
}

export type reference_child = {
	kind: "reference",
	instance: ObjectValue,
	reference: reference_use,
}

export type child = inline_child | reference_child

-- A parsed language node (or model declaration), keyed by its Instance.
export type definition = {
	id: number,
	kind: node_kind,
	instance: Instance,
	label: string,
	path: string,
	className: string,
	ownConfig: raw_config,
	-- In authored order. Always empty for models.
	children: { child },
	-- False when some children could not be parsed. Checks that depend on the
	-- complete child list are skipped to avoid cascading diagnostics.
	complete: boolean,
}

-- Facts about a source Model, read without modifying it.
export type model_facts = {
	model: Model,
	path: string,
	primaryPart: BasePart,
	-- PrimaryPart CFrame at compile time (the authoring frame).
	pivot: CFrame,
	-- Sorted by name.
	connections: { types.connection },
	connectionByName: { [string]: CFrame },
	-- Number of BaseParts named overlap among the descendants.
	overlapCount: number,
	overlapIsPrimaryPart: boolean,
}

-- Execution graph under construction (see compilation/construct). Mutable
-- until compilation/freeze turns it into the public representation.
export type edge_draft = {
	node: number,
	placement: CFrame,
	recursive: boolean,
	maxDepth: number?,
	optional: boolean,
	connection: string?,
	anchor: string?,
	contested: boolean,
	mayFail: boolean,
	key: number,
	source: types.source_info,
	-- Internal only: dropped when the graph is frozen.
	instance: Instance,
	isReference: boolean,
	-- Pick candidates only.
	weight: number,
}

export type node_draft = {
	id: number,
	kind: node_kind,
	definition: definition,
	config: node_config,
	source: types.source_info,
	-- Children, alternatives, candidates or each slots.
	edges: { edge_draft },
	-- Assemblies only.
	plugs: { edge_draft },
	complete: boolean,
	-- Assemblies: registry id of the room.
	room: number?,
	-- Models: registry id.
	model: number?,
	-- Nodes with fb_max_count.
	counter: number?,
	-- Picks: sum of candidate weights.
	totalWeight: number,
	mayFail: boolean,
}

export type graph = {
	nodes: { node_draft },
	root: number,
	counters: number,
}

-- Per-compilation state. Created once by the compilation driver.
export type session = {
	sink: diagnostics.sink,
	definitions: { definition },
	definitionOf: { [Instance]: number },
	-- ObjectValue -> definition id of its target, or false if unresolvable.
	referenceTargets: { [ObjectValue]: number | false },
	-- Memoised validated configurations (false: invalid).
	ownConfigs: { [number]: parsed_config | false },
	referenceConfigs: { [ObjectValue]: parsed_config | false },
	-- Memoised model inspection (false: invalid).
	modelFacts: { [Model]: model_facts | false },
}

return table.freeze({})
